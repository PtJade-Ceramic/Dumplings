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

$Global:DumplingsPreference['TargetVersion'] | ForEach-Object {
  if ($_) {
    # The default localization is the locale the installer declares, which the version
    # resource records as a numeric language id. VersionInfo.Language renders that id as
    # a name localized to whatever UI language the running machine uses, so read the id
    # from the PE translation table instead and let CultureInfo name the locale.
    if (-not ('ChatGLMInstallerLanguage' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ChatGLMInstallerLanguage
{
  [DllImport("version.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern int GetFileVersionInfoSize(string lptstrFilename, out int lpdwHandle);

  [DllImport("version.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool GetFileVersionInfo(string lptstrFilename, int dwHandle, int dwLen, byte[] lpData);

  [DllImport("version.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern bool VerQueryValue(byte[] pBlock, string lpSubBlock, out IntPtr lplpBuffer, out int puLen);

  public static int[] Ids(string path)
  {
    int handle;
    int size = GetFileVersionInfoSize(path, out handle);
    if (size == 0) return new int[0];
    byte[] data = new byte[size];
    if (!GetFileVersionInfo(path, 0, size, data)) return new int[0];
    IntPtr buffer;
    int length;
    if (!VerQueryValue(data, @"\VarFileInfo\Translation", out buffer, out length)) return new int[0];
    int[] ids = new int[length / 4];
    for (int index = 0; index < ids.Length; index++) ids[index] = Marshal.ReadInt16(buffer, index * 4) & 0xFFFF;
    return ids;
  }
}
'@
    }

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

    foreach ($RawManifests in Read-WinGetGitHubManifests 'ZhipuAI.ChatGLM' -PackageVersion $_ -RepoOwner ($Global:DumplingsPreference['WinGetUpstreamRepoOwner'] ?? 'microsoft') -RepoName ($Global:DumplingsPreference['WinGetUpstreamRepoName'] ?? 'winget-pkgs') -RepoBranch ($Global:DumplingsPreference['WinGetUpstreamRepoBranch'] ?? 'master') -RootPath 'manifests') {
      foreach ($Model in $RawManifests | ConvertFrom-WinGetManifestYaml) {
        foreach ($ReferenceRoot in Join-Path $env:TEMP ("chatglm-reference-" + [guid]::NewGuid().ToString('N'))) {
          foreach ($SourcePath in (, @('Identifier', 'Version' | ForEach-Object { $Model."Package$_" }) | ForEach-Object { Get-WinGetLocalPackagePath @_ -RootPath (Join-Path $ReferenceRoot 'manifests') })) {
            # The installer is downloaded here because the manifest records its hash, not its
            # metadata; the hash check keeps the evidence tied to the published package.
            foreach ($InstallerRoot in Join-Path $env:TEMP ("chatglm-installer-" + [guid]::NewGuid().ToString('N'))) {
              $null = New-Item -Path $InstallerRoot -ItemType Directory -Force
              $InstallerEntry = @($Model.Installers)[0]
              if (-not $InstallerEntry) { throw "${_}: manifest declares no installer" }
              foreach ($InstallerUrl in [string]$InstallerEntry['InstallerUrl']) {
                foreach ($InstallerPath in Join-Path $InstallerRoot (($InstallerUrl -split '/')[-1] -split '\?')[0]) {
                  Invoke-WebRequest $InstallerUrl -OutFile $InstallerPath
                  # Locate the installer whose SHA256 matches the hash recorded in the manifest, so
                  # the evidence is bound to the exact package the manifest references, then read
                  # its PE VersionInfo and its Authenticode signer.
                  foreach ($Expected in [string]$InstallerEntry['InstallerSha256'].ToUpperInvariant()) {
                    foreach ($ActualHash in (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash) { if ($ActualHash -ne $Expected) { throw "${_}: downloaded installer hash $ActualHash does not match InstallerSha256 $Expected" } }
                    $Match = Get-ChildItem -LiteralPath $InstallerRoot -Filter *.exe -File -ErrorAction SilentlyContinue | Where-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $Expected } | Select-Object -First 1
                    if (-not $Match) { throw "${_}: no installer under '$InstallerRoot' matches InstallerSha256 $Expected" }
                    $LanguageId = [ChatGLMInstallerLanguage]::Ids($Match.FullName) | Select-Object -First 1
                    if (-not $LanguageId) { throw "${_}: installer '$($Match.Name)' declares no language" }
                    $Language = [System.Globalization.CultureInfo]::GetCultureInfo([int]$LanguageId).Name
                    foreach ($VersionInfo in $Match.VersionInfo) {
                      foreach ($Signature in Get-AuthenticodeSignature -LiteralPath $Match.FullName) {
                        foreach (
                          $Fact in [pscustomobject]@{
                            Path            = $Match.FullName
                            Language        = $Language
                            LegalCopyright  = $VersionInfo.LegalCopyright
                            # Named after the manifest fields they back: CompanyName is the Add/Remove
                            # Programs Publisher, the signer common name is the Author.
                            Publisher       = $VersionInfo.CompanyName
                            SignatureStatus = $Signature.Status
                            Author          = $Signature.SignerCertificate ? $Signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) : $null
                          }
                        ) {
                          # Derived from the object itself, so a fact is added or renamed in one place only.
                          Write-Log -Object ("installer: $(($Fact.PSObject.Properties | ForEach-Object { "$($_.Name)='$($_.Value)'" }) -join ' ')")

                          $ByLocale = @{}
                          $ByLocale[[string]$Model.DefaultLocalization['PackageLocale']] = $Model.DefaultLocalization
                          @($Model.Localizations) | ForEach-Object { $ByLocale[[string]$_['PackageLocale']] = $_ }
                          $PromotedDefault = $ByLocale[$Fact.Language]
                          if (-not $PromotedDefault) { throw "${_}: no $($Fact.Language) localization in the set" }
                          # The installer declares the attribution: its company name backs Publisher and its
                          # signer legal name backs Author. A published manifest of a rewritten version can
                          # still record a superseded legal name, so adopt the installer value instead of
                          # keeping the stale one; the log line marks the change.
                          foreach ($Field in 'Publisher', 'Author') {
                            if ($PromotedDefault[$Field] -and $Fact.$Field -and $PromotedDefault[$Field] -ne $Fact.$Field) {
                              Write-Log -Object "${_}: adopting the installer $Field '$($Fact.$Field)' over the published $Field '$($PromotedDefault[$Field])'"
                              $PromotedDefault[$Field] = $Fact.$Field
                            }
                          }

                          foreach ($LocaleId in $Evidence.Locales.Keys) {
                            $Locale = $ByLocale[$LocaleId]
                            if (-not $Locale) { throw "${_}: no $LocaleId localization in the set" }
                            $Locale['Copyright'] = $Fact.LegalCopyright
                            $Evidence.Locales[$LocaleId].GetEnumerator() | ForEach-Object { $Locale[$_.Key] = $_.Value }
                            # A localization without a description reuses its short description; one that
                            # already carries a description keeps it.
                            if (-not $Locale['Description']) { $Locale['Description'] = $Locale['ShortDescription'] }
                          }

                          $Localizations = @($Model.Localizations | Where-Object { $_ -ne $PromotedDefault })
                          if ($Model.DefaultLocalization -ne $PromotedDefault) { $Localizations = @($Model.DefaultLocalization) + $Localizations }

                          # Keep the installer manifest byte-identical: this change set does not modify
                          # installer content, and the untouched file also avoids the normalizer promoting a
                          # shared ProductCode to the manifest root.
                          Save-WinGetManifest -Manifest (New-WinGetManifestModel -PackageIdentifier $Model.PackageIdentifier -PackageVersion $Model.PackageVersion -Channel $Model.Channel -Moniker 'chatglm' -ManifestVersion $Model.ManifestVersion -InstallerDefaults $Model.InstallerDefaults -Installers $Model.Installers -DefaultLocalization $PromotedDefault -Localizations $Localizations -SourceFormat Memory) -Path $SourcePath -PassThru | Out-Null
                        }
                      }
                    }
                  }
                }
              }
            }
            [IO.File]::WriteAllText((Join-Path $SourcePath "$($Model.PackageIdentifier).installer.yaml"), [string]$RawManifests['Installer'])

            Get-WinGetManifestValidationResult -Path $SourcePath | ForEach-Object {
              if ($_.HasErrors) { throw "${TargetVersion}: final validation failed:`n$(@($_.Errors | ForEach-Object { "[$($_.Id)] $($_.Message)" }) -join "`n")" }
              $_.Warnings | ForEach-Object { Write-Log -Object "[$($_.Id)] $($($_.Message))" -Level Warning }
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
    $this.CurrentState.Version = $_
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
      if (-not $_) {
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
