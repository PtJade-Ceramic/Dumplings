# ZhipuAI.ChatGLM
#
# Default run: track the version the vendor publishes in its update feed.
#
# TargetVersion run: rewrite a version that is already published instead of the
# latest one, using the locale-migration change set that microsoft/winget-pkgs#441844
# established for this package. The locale the installer declares becomes
# the default localization, the other one is demoted to an additional locale, the
# URL/documentation fields are refreshed, a localization without a description
# reuses its short description, and Copyright plus the attribution evidence are read
# from the installer the manifest references. The rewritten set is left in the local
# winget-pkgs checkout, which the submission pipeline reads as the reference for that
# existing version.

$Prefix = 'https://sfile.chatglm.cn/apk/xinyu/windows/'

foreach ($TargetVersion in @($Global:DumplingsPreference['TargetVersion'])) {
  if ($TargetVersion) {
    # Apply the migration change set to the manifest set of $TargetVersion. The
    # published manifests are read from the upstream repository, the rewritten set is
    # staged in a scratch reference repository, and LocalRepoPath points the
    # submission pipeline at that scratch repository so this existing version is its
    # own reference instead of the newest published version. The rewritten set is the
    # reference the submission pipeline reads for this version, so migration happens
    # before the state is checked and submitted.
    # The URL and documentation fields below are not carried by the installer, so they
    # are listed per locale. Description is absent because a localization without one
    # reuses its short description. The default localization, Copyright, the Add/Remove
    # Programs Publisher, and the signer legal name come from the installer at run time.
    $Evidence = @{
      Locales = @{
        'en-US' = @{
          PublisherUrl        = 'https://www.zhipuai.cn/'
          PublisherSupportUrl = 'https://www.zhipuai.cn/en/contact'
          PrivacyUrl          = 'https://chatglm.cn/privacypolicy_en'
          LicenseUrl          = 'https://chatglm.cn/agreement_en'
          CopyrightUrl        = 'https://chatglm.cn/agreement_en'
          Documentations      = @(
            @{
              DocumentLabel = 'GitHub'
              DocumentUrl   = 'https://github.com/THUDM'
            }
          )
        }
        'zh-CN' = @{
          Documentations = @(
            @{
              DocumentLabel = '开源模型'
              DocumentUrl   = 'https://github.com/THUDM'
            }
          )
        }
      }
    }

    Read-WinGetGitHubManifests 'ZhipuAI.ChatGLM' $TargetVersion -RepoOwner ($Global:DumplingsPreference['WinGetUpstreamRepoOwner'] ?? 'microsoft') -RepoName ($Global:DumplingsPreference['WinGetUpstreamRepoName'] ?? 'winget-pkgs') -RepoBranch ($Global:DumplingsPreference['WinGetUpstreamRepoBranch'] ?? 'master') -RootPath 'manifests' | ForEach-Object {
      foreach ($Model in $_ | ConvertFrom-WinGetManifestYaml) {
        foreach ($ReferenceRoot in Join-Path $env:TEMP "chatglm-reference-$([guid]::NewGuid().ToString('N'))") {
          foreach ($SourcePath in (, @('Identifier', 'Version' | ForEach-Object { $Model."Package$_" }) | ForEach-Object { Get-WinGetLocalPackagePath @_ -RootPath (Join-Path $ReferenceRoot 'manifests') })) {
            # The installer evidence is read through the shared helper, including the language
            # the installer declares: the manifest records the installer's hash, not its
            # metadata, and the hash check keeps the evidence tied to the published package.
            $InstallerEntry = @($Model.Installers)[0]
            if (-not $InstallerEntry) { throw "${TargetVersion}: manifest declares no installer" }
            foreach ($Fact in Get-WinGetInstallerEvidence -InstallerUrl ([string]$InstallerEntry['InstallerUrl']) -InstallerSha256 ([string]$InstallerEntry['InstallerSha256']) -Context $TargetVersion -Language) {
              # Derived from the object itself, so a fact is added or renamed in one place only.
              Write-Log -Object ("installer: $(($Fact.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join ' ')")

              $ByLocale = @{}
              $ByLocale[[string]$Model.DefaultLocalization['PackageLocale']] = $Model.DefaultLocalization
              @($Model.Localizations) | ForEach-Object { $ByLocale[[string]$_['PackageLocale']] = $_ }
              foreach ($PromotedDefault in , $ByLocale[$Fact['Language']]) {
                if (-not $PromotedDefault) { throw "${TargetVersion}: no $($Fact['Language']) localization in the set" }

                # The installer declares the attribution: its company name backs Publisher and its
                # signer legal name backs Author. A published manifest of a rewritten version can
                # still record a superseded legal name, so adopt the installer value instead of
                # keeping the stale one; the log line marks the change.
                'Publisher', 'Author' | ForEach-Object {
                  if ($PromotedDefault[$_] -and $Fact[$_] -and $PromotedDefault[$_] -ne $Fact[$_]) {
                    Write-Log -Object "${TargetVersion}: adopting the installer $_ '$($Fact[$_])' over the published $_ '$($PromotedDefault[$_])'"
                    $PromotedDefault[$_] = $Fact[$_]
                  }
                }

                foreach ($LocaleId in $Evidence.Locales.Keys) {
                  foreach ($Locale in , $ByLocale[$LocaleId]) {
                    if (-not $Locale) { throw "${TargetVersion}: no $LocaleId localization in the set" }
                    $Locale['Copyright'] = $Fact['LegalCopyright']
                    $Evidence.Locales[$LocaleId].GetEnumerator() | ForEach-Object { $Locale[$_.Key] = $_.Value }

                    # A localization without a description reuses its short description; one that
                    # already carries a description keeps it.
                    if (-not $Locale['Description']) { $Locale['Description'] = $Locale['ShortDescription'] }
                  }
                }

                $Localizations = @($Model.Localizations | Where-Object { $_ -ne $PromotedDefault })
                if ($Model.DefaultLocalization -ne $PromotedDefault) { $Localizations = @($Model.DefaultLocalization) + $Localizations }

                # Keep the installer manifest byte-identical: this change set does not modify
                # installer content, and the untouched file also avoids the normalizer promoting a
                # shared ProductCode to the manifest root. Save-WinGetManifest writes the published
                # text in place of the serialized document and validates the staged set with it.
                Save-WinGetManifest -Manifest ('PackageIdentifier', 'PackageVersion', 'Channel', 'ManifestVersion', 'InstallerDefaults', 'Installers' | ForEach-Object -Begin { $Table = @{} } -Process { $Table[$_] = $Model.$_ } -End { $Table } | ForEach-Object { New-WinGetManifestModel @_ -Moniker 'chatglm' -DefaultLocalization $PromotedDefault -Localizations $Localizations -SourceFormat 'Memory' }) -Path $SourcePath -InstallerManifestYaml ([string]$_['Installer']) -PassThru | Out-Null
              }
            }
            Write-Log -Object "migrated: $SourcePath"
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
  }
  else {
    $Object1 = Invoke-RestMethod "${Prefix}latest.yml" | ConvertFrom-Yaml

    # Version
    $this.CurrentState.Version = $Object1.version

    # Installer
    $this.CurrentState.Installer += [ordered]@{ InstallerUrl = $Prefix + $Object1.files[0].url }
  }

  switch -Regex ($this.Check()) {
    'New|Changed|Updated' {
      if (-not $TargetVersion) {
        try {
          # ReleaseTime
          $this.CurrentState.ReleaseTime = $Object1.releaseDate | Get-Date -AsUTC
        }
        catch {
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
