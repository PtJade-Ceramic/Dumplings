# ZhipuAI.ZCode
#
# Default run: track the version the vendor publishes in its update feed.
#
# TargetVersion run: rewrite a version that is already published instead of the latest
# one. The published manifests are read from the upstream repository, the rewritten set
# is staged in a scratch reference repository, and LocalRepoPath points the submission
# pipeline at that scratch repository so this existing version is its own reference.
# The change set is the one microsoft/winget-pkgs#445817 and microsoft/winget-pkgs#453454
# ask for: the Chinese localization carries the signer's legal name as the Author, the
# localizations that already carry a copyright take the installer's `VersionInfo.LegalCopyright`,
# the installer URL moves from the retired CDN host to the current one, and the current
# documentation URLs and moniker are backported. The locale the installer declares becomes
# the default localization; the published default is demoted when the declared locale differs.

foreach ($TargetVersion in @($Global:DumplingsPreference['TargetVersion'])) {
  if ($TargetVersion) {
    # The URL and documentation fields below are not carried by the installer, so they are
    # listed per locale. The Chinese localization carries the signer's legal name, or the
    # authored fallback when the installer is unsigned; the other localizations keep their
    # authored author strings.
    foreach (
      $Evidence in @{
        AuthorLocale   = 'zh-CN'
        # A few versions (0.9.1, 0.14.2) are unsigned, so their signer's name cannot be read;
        # the legal name of the entity is authored once and used for those versions instead.
        # The entity has carried the joint-stock name since May 2025 (the signer certificate
        # in use from then was issued on 2025-05-21), before ZCode launched; the '有限公司'
        # spelling in the published manifests is a stale authored value.
        AuthorFallback = '北京智谱华章科技股份有限公司'
        # The current published metadata the rewrite backports, listed per locale; the
        # moniker is passed to the model instead because WinGet stores it in the default
        # localization document.
        Locales        = [ordered]@{
          'zh-CN' = [ordered]@{
            PublisherSupportUrl = 'https://zcode.z.ai/docs/feedback'
            PrivacyUrl          = 'https://zcode.z.ai/privacy'
            LicenseUrl          = 'https://zcode.z.ai/terms'
            CopyrightUrl        = 'https://zcode.z.ai/terms'
            ReleaseNotesUrl     = 'https://zcode.z.ai/changelog'
            Documentations      = @(
              [ordered]@{ DocumentLabel = '发布者网站文档'; DocumentUrl = 'https://zcode.z.ai/docs/welcome' }
              [ordered]@{ DocumentLabel = '飞书文档'; DocumentUrl = 'https://zhipu-ai.feishu.cn/wiki/VpgrwtBcyiU59zk9fMEcm2sFnee' }
              [ordered]@{ DocumentLabel = '提交漏洞'; DocumentUrl = 'https://zcode.z.ai/zsrc' }
            )
          }
          'en-US' = [ordered]@{
            PublisherSupportUrl = 'https://zcode.z.ai/docs/feedback'
            PrivacyUrl          = 'https://zcode.z.ai/privacy'
            LicenseUrl          = 'https://zcode.z.ai/terms'
            CopyrightUrl        = 'https://zcode.z.ai/terms'
            ReleaseNotesUrl     = 'https://zcode.z.ai/changelog'
            Documentations      = @(
              [ordered]@{ DocumentLabel = 'Docs on Publisher''s website'; DocumentUrl = 'https://zcode.z.ai/docs/welcome' }
              [ordered]@{ DocumentLabel = 'Docs on Feishu'; DocumentUrl = 'https://zhipu-ai.feishu.cn/wiki/VpgrwtBcyiU59zk9fMEcm2sFnee' }
              [ordered]@{ DocumentLabel = 'Report a vulnerability'; DocumentUrl = 'https://zcode.z.ai/zsrc' }
            )
          }
        }
      }
    ) {
      # Apply the change set to the manifest set of $TargetVersion. The published manifests are read
      # from the upstream repository, the rewritten set is staged in a scratch reference repository,
      # and LocalRepoPath points the submission pipeline at that scratch repository so this existing
      # version is its own reference instead of the newest published version. The rewritten set is the
      # reference the submission pipeline reads for this version, so the rewrite happens before the
      # state is checked and submitted.
      foreach ($RawManifests in Read-WinGetGitHubManifests 'ZhipuAI.ZCode' $TargetVersion -RepoOwner ($Global:DumplingsPreference['WinGetUpstreamRepoOwner'] ?? 'microsoft') -RepoName ($Global:DumplingsPreference['WinGetUpstreamRepoName'] ?? 'winget-pkgs') -RepoBranch ($Global:DumplingsPreference['WinGetUpstreamRepoBranch'] ?? 'master') -RootPath 'manifests') {
        foreach ($Model in $RawManifests | ConvertFrom-WinGetManifestYaml) {
          foreach ($ReferenceRoot in Join-Path $env:TEMP ("zcode-reference-$([guid]::NewGuid().ToString('N'))")) {
            foreach ($SourcePath in (, @('Identifier', 'Version' | ForEach-Object { $Model."Package$_" }) | ForEach-Object { Get-WinGetLocalPackagePath @_ -RootPath (Join-Path $ReferenceRoot 'manifests') })) {
              # The installer evidence is read through the shared helper, including the language
              # the installer declares: the manifest records the installer's hash, not its metadata,
              # and the hash check keeps the evidence tied to the published package. The retired CDN
              # host in the published URL no longer resolves outside China while the current host
              # still serves the same objects, so the evidence download runs against the migrated URL
              # and the published hash then proves the migrated object is the published one.
              $InstallerEntry = @($Model.Installers)[0]
              if (-not $InstallerEntry) { throw "${TargetVersion}: manifest declares no installer" }
              foreach ($PublishedUrl in [string]$InstallerEntry['InstallerUrl']) {
                foreach ($MigratedUrl in $PublishedUrl -replace '^https://cdn\.zcode-ai\.com/', 'https://cdn-zcode.z.ai/') {
                  Get-WinGetInstallerEvidence -InstallerUrl $MigratedUrl -InstallerSha256 ([string]$InstallerEntry['InstallerSha256']) -Context $TargetVersion -Language | ForEach-Object {
                    # Derived from the object itself, so a fact is added or renamed in one place only.
                    Write-Log -Object ("installer: $(($_.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join ' ')")

                    $ByLocale = @{}
                    $ByLocale[[string]$Model.DefaultLocalization['PackageLocale']] = $Model.DefaultLocalization
                    @($Model.Localizations) | ForEach-Object { $ByLocale[[string]$_['PackageLocale']] = $_ }

                    foreach ($PromotedDefault in , $ByLocale[$_['Language']]) {
                      if (-not $PromotedDefault) { throw "${TargetVersion}: no $($_['Language']) localization in the set" }

                      # The signer's legal name is the current name of the entity; an unsigned
                      # installer has no signer to read, so the authored fallback is used instead.
                      # A localization that carries no author is left without one.
                      $AuthorLocale = $ByLocale[$Evidence['AuthorLocale']]
                      if (-not $AuthorLocale) { throw "${TargetVersion}: no $($Evidence['AuthorLocale']) localization in the set" }
                      $Author = $_['Author']
                      if (-not $Author) { $Author = [string]$Evidence['AuthorFallback'] }
                      if ($AuthorLocale['Author'] -and $Author -and ([string]$AuthorLocale['Author'] -cne $Author)) {
                        Write-Log -Object "Author ($($Evidence['AuthorLocale'])): '$([string]$AuthorLocale['Author'])' -> '$Author'"
                        $AuthorLocale['Author'] = $Author
                      }

                      foreach ($LocaleId in $ByLocale.Keys) {
                        $Locale = $ByLocale[$LocaleId]
                        if (-not $Locale.Contains('Copyright')) { continue }
                        if ([string]$Locale['Copyright'] -cne [string]$_['LegalCopyright']) {
                          Write-Log -Object "Copyright ($LocaleId): '$($Locale['Copyright'])' -> '$($_['LegalCopyright'])'"
                          $Locale['Copyright'] = $_['LegalCopyright']
                        }
                      }

                      # The current published metadata is backported per listed locale.
                      foreach ($LocaleId in $Evidence['Locales'].Keys) {
                        foreach ($Locale in , $ByLocale[$LocaleId]) {
                          if (-not $Locale) { throw "${TargetVersion}: no $LocaleId localization in the set" }
                          $Evidence['Locales'][$LocaleId].GetEnumerator() | ForEach-Object { $Locale[$_.Key] = $_.Value }
                        }
                      }

                      # The migration rewrites the installer URL of the set, so the migrated URL replaces
                      # the published one on the entry as well: the entry is what the task state carries
                      # into the submission, and the staged installer text below carries the same URL.
                      if ($MigratedUrl -cne $PublishedUrl) {
                        Write-Log -Object "InstallerUrl: '$PublishedUrl' -> '$MigratedUrl'"
                        $InstallerEntry['InstallerUrl'] = $MigratedUrl
                      }

                      # The locale the installer declares becomes the default localization; the
                      # published default joins the additional localizations when the roles change.
                      $Localizations = @($Model.Localizations | Where-Object { $_ -ne $PromotedDefault })
                      if ($Model.DefaultLocalization -ne $PromotedDefault) { $Localizations = @($Model.DefaultLocalization) + $Localizations }

                      # Stage the installer manifest from the published text with only the migrated URL
                      # in place: the rest stays byte-identical, which also avoids the normalizer
                      # promoting a shared ProductCode to the manifest root. Save-WinGetManifest writes
                      # the staged text in place of the serialized document and validates the staged
                      # set with it. The moniker is a model-level field; it lands in the default
                      # localization document.
                      'PackageIdentifier', 'PackageVersion', 'Channel', 'ManifestVersion', 'InstallerDefaults', 'Installers' | ForEach-Object -Begin { $Table = @{} } -Process { $Table[$_] = $Model.$_ } -End { $Table } | ForEach-Object { New-WinGetManifestModel @_ -Moniker 'zcode' -DefaultLocalization $PromotedDefault -Localizations $Localizations -SourceFormat Memory } | Save-WinGetManifest -Path $SourcePath -InstallerManifestYaml ([string]$RawManifests['Installer']).Replace($PublishedUrl, $MigratedUrl) -PassThru | Out-Null
                    }
                  }
                }
              }
              Write-Log -Object "rewritten: $SourcePath"
            }

            # Point the submission pipeline at the scratch repository so this existing
            # version is read as its own reference.
            $Global:DumplingsPreference['LocalRepoPath'] = $ReferenceRoot
          }
        }
      }
    }
    # The submission pipeline updates the installers from the task state, so declare the
    # installer entries the reference manifests carry, with the migrated URL applied.
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
