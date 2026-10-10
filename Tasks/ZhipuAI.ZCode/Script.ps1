# ZhipuAI.ZCode
#
# Default run: track the version the vendor publishes in its update feed.
#
# TargetVersion run: rewrite a version that is already published instead of the latest
# one. The published manifests are read from the upstream repository, the rewritten set
# is staged in a scratch reference repository, and LocalRepoPath points the submission
# pipeline at that scratch repository so this existing version is its own reference.
# The change set is the one microsoft/winget-pkgs#445817 asks for: the Chinese
# localization carries the signer's legal name as the Author, and the localizations that
# already carry a copyright take the installer's VersionInfo.LegalCopyright. The
# localization roles stay as authored because the installer declares en-US, which is
# already the default localization.

$Global:DumplingsPreference['TargetVersion'] | ForEach-Object {
  $TargetVersion = $_
  if ($TargetVersion) {
    # The URL and documentation fields are not carried by the installer, so they are left as
    # authored. The Chinese localization carries the signer's legal name; the other localizations
    # keep their authored author strings.
    $Evidence = @{
      AuthorLocale = 'zh-CN'
    }

    # Apply the change set to the manifest set of $TargetVersion. The published manifests are read
    # from the upstream repository, the rewritten set is staged in a scratch reference repository,
    # and LocalRepoPath points the submission pipeline at that scratch repository so this existing
    # version is its own reference instead of the newest published version. The rewritten set is the
    # reference the submission pipeline reads for this version, so the rewrite happens before the
    # state is checked and submitted.
    foreach ($RawManifests in Read-WinGetGitHubManifests 'ZhipuAI.ZCode' $TargetVersion -RepoOwner ($Global:DumplingsPreference['WinGetUpstreamRepoOwner'] ?? 'microsoft') -RepoName ($Global:DumplingsPreference['WinGetUpstreamRepoName'] ?? 'winget-pkgs') -RepoBranch ($Global:DumplingsPreference['WinGetUpstreamRepoBranch'] ?? 'master') -RootPath 'manifests') {
      foreach ($Model in $RawManifests | ConvertFrom-WinGetManifestYaml) {
        foreach ($ReferenceRoot in Join-Path $env:TEMP ("zcode-reference-" + [guid]::NewGuid().ToString('N'))) {
          foreach ($SourcePath in (, @('Identifier', 'Version' | ForEach-Object { $Model."Package$_" }) | ForEach-Object { Get-WinGetLocalPackagePath @_ -RootPath (Join-Path $ReferenceRoot 'manifests') })) {
            # The installer is downloaded here because the manifest records its hash, not its
            # metadata; the hash check keeps the evidence tied to the published package.
            foreach ($InstallerRoot in Join-Path $env:TEMP ("zcode-installer-" + [guid]::NewGuid().ToString('N'))) {
              $null = New-Item -Path $InstallerRoot -ItemType Directory -Force
              $InstallerEntry = @($Model.Installers)[0]
              if (-not $InstallerEntry) { throw "${TargetVersion}: manifest declares no installer" }
              foreach ($InstallerUrl in [string]$InstallerEntry['InstallerUrl']) {
                foreach ($InstallerPath in Join-Path $InstallerRoot (($InstallerUrl -split '/')[-1] -split '\?')[0]) {
                  Invoke-WebRequest $InstallerUrl -OutFile $InstallerPath
                  # Locate the installer whose SHA256 matches the hash recorded in the manifest, so
                  # the evidence is bound to the exact package the manifest references, then read
                  # its PE VersionInfo and its Authenticode signer.
                  foreach ($Expected in [string]$InstallerEntry['InstallerSha256'].ToUpperInvariant()) {
                    (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash | ForEach-Object { if ($_ -ne $Expected) { throw "${TargetVersion}: downloaded installer hash $_ does not match InstallerSha256 $Expected" } }
                    $Match = Get-ChildItem -LiteralPath $InstallerRoot -Filter *.exe -File -ErrorAction SilentlyContinue | Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $Expected } | Select-Object -First 1
                    if (-not $Match) { throw "${TargetVersion}: no installer under '$InstallerRoot' matches InstallerSha256 $Expected" }
                    foreach (
                      $Fact in & {
                        $Fact = [ordered]@{
                          Path = $Match.FullName
                        }
                        $Match.VersionInfo | ForEach-Object {
                          $Fact.LegalCopyright = $_.LegalCopyright
                          # Named after the manifest field it backs: CompanyName is the Add/Remove
                          # Programs Publisher. This package does not declare one.
                          $Fact.Publisher = $_.CompanyName
                        }
                        Get-AuthenticodeSignature -LiteralPath $Match.FullName | ForEach-Object {
                          $Fact.SignatureStatus = $_.Status
                          $Fact.Author = ($_.SignerCertificate ? $_.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) : $null)
                        }
                        $Fact
                      }
                    ) {
                      # Derived from the object itself, so a fact is added or renamed in one place only.
                      Write-Log -Object ("installer: $(($Fact.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join ' ')")

                      $ByLocale = @{}
                      $ByLocale[[string]$Model.DefaultLocalization['PackageLocale']] = $Model.DefaultLocalization
                      @($Model.Localizations) | ForEach-Object { $ByLocale[[string]$_['PackageLocale']] = $_ }

                      # The signer's legal name is the current name of the entity, so it replaces
                      # the authored name in the localization that carries it. An unsigned
                      # installer has no such evidence and must stop the rewrite instead.
                      $AuthorLocale = $ByLocale[$Evidence.AuthorLocale]
                      if (-not $AuthorLocale) { throw "${TargetVersion}: no $($Evidence.AuthorLocale) localization in the set" }
                      if (-not $Fact.Author) { throw "${TargetVersion}: installer '$($Match.Name)' is not signed by a certificate with a common name" }
                      $PreviousAuthor = [string]$AuthorLocale['Author']
                      $AuthorLocale['Author'] = $Fact.Author
                      Write-Log -Object "Author ($($Evidence.AuthorLocale)): '$PreviousAuthor' -> '$($Fact.Author)'"

                      foreach ($LocaleId in $ByLocale.Keys) {
                        $Locale = $ByLocale[$LocaleId]
                        if (-not $Locale.Contains('Copyright')) { continue }
                        if ([string]$Locale['Copyright'] -cne [string]$Fact.LegalCopyright) {
                          Write-Log -Object "Copyright ($LocaleId): '$($Locale['Copyright'])' -> '$($Fact.LegalCopyright)'"
                          $Locale['Copyright'] = $Fact.LegalCopyright
                        }
                      }

                      # Keep the localization roles as authored: the installer declares en-US, which
                      # is already the default localization, so neither locale is promoted. Only
                      # the fields above change.
                      $PromotedDefault = $Model.DefaultLocalization
                      $Localizations = @($Model.Localizations | Where-Object { $_ -ne $PromotedDefault })

                      # Keep the installer manifest byte-identical: this change set does not modify
                      # installer content, and the untouched file also avoids the normalizer
                      # promoting a shared ProductCode to the manifest root.
                      Save-WinGetManifest -Manifest (New-WinGetManifestModel -PackageIdentifier $Model.PackageIdentifier -PackageVersion $Model.PackageVersion -Channel $Model.Channel -Moniker ([string]$Model.Moniker) -ManifestVersion $Model.ManifestVersion -InstallerDefaults $Model.InstallerDefaults -Installers $Model.Installers -DefaultLocalization $PromotedDefault -Localizations $Localizations -SourceFormat Memory) -Path $SourcePath -PassThru | Out-Null
                    }
                  }
                }
              }
            }
            [IO.File]::WriteAllText((Join-Path $SourcePath "$($Model.PackageIdentifier).installer.yaml"), [string]$RawManifests['Installer'])

            Get-WinGetManifestValidationResult -Path $SourcePath | ForEach-Object {
              if ($_.HasErrors) { throw "${TargetVersion}: final validation failed:`n$(@($_.Errors | ForEach-Object { "[$($_.Id)] $($_.Message)" }) -join "`n")" }
              $_.Warnings | ForEach-Object { Write-Log -Object "[$($_.Id)] $($_.Message)" -Level Warning }
            }
            Write-Log -Object "rewritten: $SourcePath"
          }

          # Point the submission pipeline at the scratch repository so this existing
          # version is read as its own reference.
          $Global:DumplingsPreference['LocalRepoPath'] = $ReferenceRoot
        }
      }
    }
    # The installers are not part of this change set, but the submission pipeline updates them
    # from the task state, so declare the installers the reference manifests already carry.
    $this.CurrentState.Installer = @($Model.Installers)
    $this.CurrentState.Version = $TargetVersion
  } else {
    $Object1 = curl -fsSLA $DumplingsInternetExplorerUserAgent 'https://zcode-ai.com/api/v2/releases/latest?target=windows&arch=x86_64' | Join-String -Separator "`n" | ConvertFrom-Json
    $Object2 = curl -fsSLA $DumplingsInternetExplorerUserAgent 'https://zcode-ai.com/api/v2/releases/latest?target=windows&arch=aarch64' | Join-String -Separator "`n" | ConvertFrom-Json

    if ($Object1.version -ne $Object2.version) {
      $this.Log("Inconsistent versions: x64: $($Object1.version), arm64: $($Object2.version)", 'Error')
      return
    }

    # Version
    $this.CurrentState.Version = $Object1.version

    # Installer
    $this.CurrentState.Installer += [ordered]@{
      Architecture = 'x64'
      InstallerUrl = $Object1.installer_url
    }
    $this.CurrentState.Installer += [ordered]@{
      Architecture = 'arm64'
      InstallerUrl = $Object2.installer_url
    }
  }

  switch -Regex ($this.Check()) {
    'New|Changed|Updated' {
      if (-not $TargetVersion) {
        try {
          # ReleaseTime
          $this.CurrentState.ReleaseTime = $Object1.published_at | ConvertFrom-UnixTimeMilliseconds
        } catch {
          $_ | Out-Host
          $this.Log($_, 'Warning')
        }

        try {
          $Object3 = Invoke-RestMethod -Uri $Object1.changelog_url | ConvertFrom-Yaml

          # ReleaseNotes (zh-CN)
          $this.CurrentState.Locale += [ordered]@{
            Locale = 'zh-CN'
            Key    = 'ReleaseNotes'
            Value  = $Object3.releaseNotes | Convert-MarkdownToHtml | Get-TextContent | Format-Text
          }
        } catch {
          $_ | Out-Host
          $this.Log($_, 'Warning')
        }
      }

      $this.Print()
      $this.Write()
    }
    'Changed|Updated' {
      $this.Message()
    }
    'Updated' {
      $this.Submit()
    }
  }
}
