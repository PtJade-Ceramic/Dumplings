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

foreach ($TargetVersion in @($Global:DumplingsPreference['TargetVersion'])) {
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
            # The installer evidence is read through the shared helper: the manifest records the
            # installer's hash, not its metadata, and the hash check keeps the evidence tied to
            # the published package.
            $InstallerEntry = @($Model.Installers)[0]
            if (-not $InstallerEntry) { throw "${TargetVersion}: manifest declares no installer" }
            Get-WinGetInstallerEvidence -InstallerUrl ([string]$InstallerEntry['InstallerUrl']) -InstallerSha256 ([string]$InstallerEntry['InstallerSha256']) -Context $TargetVersion | ForEach-Object {
              # Derived from the object itself, so a fact is added or renamed in one place only.
              Write-Log -Object ("installer: $(($_.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join ' ')")

              $ByLocale = @{}
              $ByLocale[[string]$Model.DefaultLocalization['PackageLocale']] = $Model.DefaultLocalization
              @($Model.Localizations) | ForEach-Object { $ByLocale[[string]$_['PackageLocale']] = $_ }

              # The signer's legal name is the current name of the entity, so it replaces
              # the authored name in the localization that carries it. An unsigned
              # installer has no such evidence and must stop the rewrite instead.
              $AuthorLocale = $ByLocale[$Evidence.AuthorLocale]
              if (-not $AuthorLocale) { throw "${TargetVersion}: no $($Evidence.AuthorLocale) localization in the set" }
              if (-not $_['Author']) { throw "${TargetVersion}: installer '$([IO.Path]::GetFileName($_['Path']))' is not signed by a certificate with a common name" }
              Write-Log -Object "Author ($($Evidence.AuthorLocale)): '$([string]$AuthorLocale['Author'])' -> '$($_['Author'])'"
              $AuthorLocale['Author'] = $_['Author']

              foreach ($LocaleId in $ByLocale.Keys) {
                $Locale = $ByLocale[$LocaleId]
                if (-not $Locale.Contains('Copyright')) { continue }
                if ([string]$Locale['Copyright'] -cne [string]$_['LegalCopyright']) {
                  Write-Log -Object "Copyright ($LocaleId): '$($Locale['Copyright'])' -> '$($_['LegalCopyright'])'"
                  $Locale['Copyright'] = $_['LegalCopyright']
                }
              }
            }

            # Keep the localization roles as authored: the installer declares en-US, which
            # is already the default localization, so neither locale is promoted. Only
            # the fields above change.
            foreach ($PromotedDefault in $Model.DefaultLocalization) {
              # Keep the installer manifest byte-identical: this change set does not modify
              # installer content, and the untouched file also avoids the normalizer promoting a
              # shared ProductCode to the manifest root. Save-WinGetManifest writes the published
              # text in place of the serialized document and validates the staged set with it.
              Save-WinGetManifest -Manifest ('PackageIdentifier', 'PackageVersion', 'Channel', 'Moniker', 'ManifestVersion', 'InstallerDefaults', 'Installers' | ForEach-Object -Begin { $Table = @{} } -Process { $Table[$_] = $Model.$_ } -End { $Table } | ForEach-Object { New-WinGetManifestModel @_ -DefaultLocalization $PromotedDefault -Localizations (@($Model.Localizations | Where-Object { $_ -ne $PromotedDefault })) -SourceFormat Memory }) -Path $SourcePath -InstallerManifestYaml ([string]$RawManifests['Installer']) -PassThru | Out-Null
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
