# BlueStack.BlueStacks
#
# The download article carries the current installer, and the release-notes article lists one
# heading per build. The publisher publishes both articles in every language its help centre
# serves, and each localized page states the language it is written in, so the task reads the
# page's own <html lang> instead of guessing a locale from the URL. Only the publisher's own text
# is authored: nothing is translated by this task, which is why no Simplified Chinese text is
# derived from the Traditional Chinese page (see microsoft/winget-pkgs#445891).
#
# A TargetVersion run rewrites a version that is already published instead of the version the
# download article serves, which is how a published locale tag is corrected (see
# microsoft/winget-pkgs#488216). That run keeps the published manifests and notes as they are and
# only renames the locale tags the publisher states differently today, using the languages of the
# download article because the help centre serves the same language set for every release. It
# writes no state, because the task must keep tracking the version the download article serves.
# A normal run can only change the locales the previous version declares, so a tag the publisher
# restates is carried forward until a TargetVersion run corrects it.
#
# The help centre answers some automated clients with HTTP 403, so every page read falls back to
# the shared stealth browser lease. Its canonical /hc/articles/<id> URL is not authored either:
# winget-pkgs URL validation reports it as Forbidden, which is why the published manifests carry
# no ReleaseNotesUrl or Documentations.

function Get-BlueStacksPageContent {
  <#
  .SYNOPSIS
    Read a BlueStacks help-centre page
  .PARAMETER Uri
    The page to read
  .NOTES
    A failed plain request is retried through the shared stealth browser lease, because the help
    centre answers some automated clients with HTTP 403.
  #>
  param (
    [Parameter(Position = 0, Mandatory)]
    [string]$Uri
  )

  try {
    return (Invoke-WebRequest -Uri $Uri -ErrorAction Stop).Content
  } catch {
    return (Invoke-PlaywrightFetch -Uri $Uri -Headless -Stealth -WaitUntil Load).Content
  }
}

# Installer
$DownloadArticle = Get-BlueStacksPageContent -Uri 'https://support.bluestacks.com/hc/en-us/articles/4402611273485' | ConvertFrom-Html
$DownloadArticleBody = $DownloadArticle.SelectSingleNode("//div[@itemprop='articleBody']")
if (-not $DownloadArticleBody) {
  throw 'The download article has no article body'
}

$InstallerLinks = @(
  foreach ($Link in $DownloadArticleBody.SelectNodes('.//a[@href]')) {
    $Match = [regex]::Match($Link.Attributes['href'].Value, '_(?<Version>\d+\.\d+\.\d+\.\d+)_(?<Architecture>amd64|x86|arm64)_native\.exe$')
    if ($Match.Success) {
      [ordered]@{
        Version      = $Match.Groups['Version'].Value
        Architecture = $Match.Groups['Architecture'].Value
        InstallerUrl = Join-Uri 'https://support.bluestacks.com/' $Link.Attributes['href'].Value
      }
    }
  }
)
if ($InstallerLinks.Count -eq 0) {
  throw 'The download article lists no installer link'
}

# The publisher leaves the x86 link at an older build, so only the entries of the newest version
# describe this release.
$LatestVersion = ($InstallerLinks | Sort-Object -Property { [version]$_.Version } -Bottom 1).Version
$MajorMinorVersion = ($LatestVersion -split '\.')[0..1] -join '.'
$BuildVersion = ($LatestVersion -split '\.')[0..2] -join '.'

$TargetVersion = $Global:DumplingsPreference['TargetVersion']
# A targeted rewrite points the submission pipeline at a staged copy of the published manifests;
# both values let the run restore the shared preference and remove the copy when it is done.
$ReferenceRoot = $null
$PreviousLocalRepoPath = $null

try {
  # The article's hreflang alternates are the publisher's own list of every language it serves for
  # the article, and each localized page states the language it is written in. A language the
  # publisher has not translated answers with the English page, which is left out because the page
  # disagrees with its own hreflang.
  $Alternates = @(
    $(
      # The language set is a property of the help centre rather than of one release, so a targeted
      # rewrite reads it from the download article instead of the release notes of the version it
      # rewrites.
      if ($TargetVersion) {
        $DownloadArticle
      } else {
        # The release-notes section lists one article per release, so the article of this release is
        # looked up by the heading the publisher gives it.
        $ArticleLink = (Get-BlueStacksPageContent -Uri 'https://support.bluestacks.com/hc/en-us/sections/360012290292' | ConvertFrom-Html).SelectNodes("//ul[contains(@class, 'article-list')]//a") |
          Where-Object -FilterScript { ($_.InnerText -replace '\s+', ' ').Trim() -ceq "BlueStacks $MajorMinorVersion Release Notes" } |
          Select-Object -First 1
          if (-not $ArticleLink) { throw "The release-notes section lists no article for BlueStacks $MajorMinorVersion" }
          Get-BlueStacksPageContent -Uri (Join-Uri 'https://support.bluestacks.com/' $ArticleLink.Attributes['href'].Value) | ConvertFrom-Html
        }
      ).SelectNodes('//link[@rel="alternate"][@hreflang][@href]') |
        Where-Object -FilterScript { $_.GetAttributeValue('hreflang', '') -cne 'x-default' } |
        ForEach-Object -Process {
          [pscustomobject]@{
            Locale = $_.GetAttributeValue('hreflang', '')
            Url    = $_.GetAttributeValue('href', '')
          }
        }
  )
  if ($Alternates.Count -eq 0) { throw 'The article lists no hreflang alternate' }

  # A page that reports a language other than its own hreflang is the English page the publisher
  # serves for a language it has not translated, so only the pages that agree are kept.
  $LocalizedPages = @(
    $Alternates | ForEach-Object -Process {
      $LocaleName = $_.Locale

      try {
        $LocaleArticle = Get-BlueStacksPageContent -Uri $_.Url | ConvertFrom-Html
        $PageLanguage = $LocaleArticle.SelectSingleNode('//html')?.GetAttributeValue('lang', '')

        if ($PageLanguage -ine $LocaleName) {
          $this.Log("Skipping the ${LocaleName} page because it reports ${PageLanguage}", 'Verbose')
          return
        }

        [pscustomobject]@{
          Locale  = $PageLanguage
          Article = $LocaleArticle
        }
      } catch {
        $this.Log("Failed to read the ${LocaleName} page: ${_}", 'Warning')
      }
    }
  )
} catch {
  $this.Log($_, 'Warning')
  $LocalizedPages = @()
}
$LiveLocale = @($LocalizedPages | ForEach-Object -Process { $_.Locale })
if ($TargetVersion) {
  # The published manifests of the requested version are the reference of this submission, so the
  # rewrite applies to that version instead of the newest one. The set is staged byte for byte and
  # LocalRepoPath points the submission pipeline at the staged copy.
  $PublishedManifests = @(Read-WinGetGitHubManifests -PackageIdentifier 'BlueStack.BlueStacks' -PackageVersion $TargetVersion -RepoOwner ($Global:DumplingsPreference['WinGetUpstreamRepoOwner'] ?? 'microsoft') -RepoName ($Global:DumplingsPreference['WinGetUpstreamRepoName'] ?? 'winget-pkgs') -RepoBranch ($Global:DumplingsPreference['WinGetUpstreamRepoBranch'] ?? 'master') -RootPath 'manifests')
  if ($PublishedManifests.Count -ne 1) { throw "The published manifests of version ${TargetVersion} could not be read" }
  $PublishedManifests = $PublishedManifests[0]

  $ReferenceRoot = Join-Path $Env:TEMP "bluestacks-reference-$([guid]::NewGuid().ToString('N'))"
  $ReferenceVersionPath = Get-WinGetLocalPackagePath -PackageIdentifier 'BlueStack.BlueStacks' -PackageVersion $TargetVersion -RootPath (Join-Path $ReferenceRoot 'manifests')
  $null = New-Item -Path $ReferenceVersionPath -ItemType Directory -Force
  $PublishedManifests['Version'] | Set-Content -Path (Join-Path $ReferenceVersionPath 'BlueStack.BlueStacks.yaml') -NoNewline
  if ($PublishedManifests['Installer']) {
    $PublishedManifests['Installer'] | Set-Content -Path (Join-Path $ReferenceVersionPath 'BlueStack.BlueStacks.installer.yaml') -NoNewline
  }
  $PublishedManifests['Locale'].GetEnumerator() | ForEach-Object {
    $_.Value | Set-Content -Path (Join-Path $ReferenceVersionPath "BlueStack.BlueStacks.locale.$($_.Key).yaml") -NoNewline
  }
  $PreviousLocalRepoPath = $Global:DumplingsPreference['LocalRepoPath']
  $Global:DumplingsPreference['LocalRepoPath'] = $ReferenceRoot

  $PublishedModel = $PublishedManifests | ConvertFrom-WinGetManifestYaml

  # Version
  $this.CurrentState.Version = $TargetVersion

  # Installer
  # The published entries carry their own hashes, so the submission reuses them instead of
  # downloading and analysing the installers of an unchanged version.
  $this.CurrentState.Installer = @($PublishedModel.Installers | ForEach-Object -Process { Copy-Object -Value $_ })

  # Locale alignment
  $PublishedLocale = [ordered]@{}
  $PublishedNotes = [ordered]@{}
  @($PublishedModel.DefaultLocalization) + @($PublishedModel.Localizations) | ForEach-Object {
    $PublishedTag = [string]$_['PackageLocale']
    $PublishedLocale[$PublishedTag] = $true
    if ($_.Contains('ReleaseNotes')) { $PublishedNotes[$PublishedTag] = $_['ReleaseNotes'] }
  }

  $AlignedLocale = [ordered]@{}
  foreach ($PublishedLocaleTag in $PublishedLocale.Keys) {
    if ($LiveLocale -ccontains $PublishedLocaleTag) {
      $AlignedLocale[$PublishedLocaleTag] = $PublishedLocaleTag
      continue
    }

    $Candidates = @($LiveLocale | Where-Object -FilterScript { ($_ -split '-')[0] -ieq ($PublishedLocaleTag -split '-')[0] })
    if ($Candidates.Count -ne 1) {
      $this.Log("The publisher states no single language for the published ${PublishedLocaleTag} locale", 'Warning')
      $AlignedLocale[$PublishedLocaleTag] = $PublishedLocaleTag
      continue
    }

    $AlignedLocale[$PublishedLocaleTag] = $Candidates[0]
    # A locale document is inherited from the reference and can only be changed, so the published
    # tag is renamed in place. The entry has to precede the notes below, which already target the
    # aligned tag.
    $this.CurrentState.Locale += [ordered]@{
      Locale = $PublishedLocaleTag
      Key    = 'PackageLocale'
      Value  = $Candidates[0]
    }
  }
  $LiveLocale | ForEach-Object {
    if ($AlignedLocale.Values -ccontains $_) { return }
    # Locale documents cannot be created, so a language the published set does not declare cannot
    # be added by this task.
    $this.Log("The published set declares no ${_} locale, so no locale is added for it", 'Warning')
  }

  # The inherited locale documents are stripped of their notes before the delivery, so the
  # published notes are re-applied on the aligned tag.
  $PublishedNotes.Keys | ForEach-Object {
    $this.CurrentState.Locale += [ordered]@{
      Locale = $AlignedLocale[$_]
      Key    = 'ReleaseNotes'
      Value  = $PublishedNotes[$_]
    }
  }
} else {
  # Version
  $this.CurrentState.Version = $LatestVersion

  # Installer
  $InstallerLinks | Where-Object -FilterScript { $_.Version -ceq $LatestVersion } | ForEach-Object {
    $this.CurrentState.Installer += [ordered]@{
      Architecture = $_.Architecture -ceq 'amd64' ? 'x64' : $_.Architecture
      InstallerUrl = $_.InstallerUrl
    }
  }

  # Release notes
  $LocalizedPages | ForEach-Object {
    $PageLanguage = $_.Locale
    $LocaleArticle = $_.Article

    try {
      if (@($this.CurrentState.Locale).Where({ $_.Locale -ieq $PageLanguage }).Count -ne 0) { return }

      $TitleNode = $LocaleArticle.SelectNodes("//div[@itemprop='articleBody']//*[self::h3 or self::h4]") |
        Where-Object -FilterScript { ($_.InnerText -replace '\s+', ' ') -like "*$BuildVersion*" } |
        Select-Object -First 1

        if (-not $TitleNode) {
          $this.Log("No ${PageLanguage} release notes heading for version $BuildVersion", 'Warning')
          return
        }

        $ReleaseNotesNodes = @(
          for ($Node = $TitleNode.NextSibling; $Node -and $Node.Name -notin @('h3', 'h4'); $Node = $Node.NextSibling) {
            # A separator, a blank text node, or the download button every entry repeats is not part of the notes
            if (
              $Node.Name -ceq 'hr' -or
              [string]::IsNullOrWhiteSpace($Node.InnerText) -or
              $Node.SelectSingleNode('.//a[@class="btn-download"]')
            ) { continue }
            $Node
          }
        )

        # Each entry closes with a localized "released on" line carrying a calendar year. It
        # supplies the release date and is not part of the notes.
        if ($ReleaseNotesNodes.Count -gt 0 -and $ReleaseNotesNodes[-1].InnerText -match '20\d{2}') {
          if (-not $this.CurrentState['ReleaseTime']) {
            $ReleaseTime = [datetime]::MinValue
            if ([datetime]::TryParse(($ReleaseNotesNodes[-1].InnerText -replace '^\s*\S+\s+\S+\s+', '').Trim(), [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$ReleaseTime)) {
              $this.CurrentState.ReleaseTime = $ReleaseTime.ToString('yyyy-MM-dd')
            }
          }
          $ReleaseNotesNodes = @($ReleaseNotesNodes | Select-Object -SkipLast 1)
        }

        $ReleaseNotes = $ReleaseNotesNodes | Get-TextContent | Format-Text
        if ($ReleaseNotes) {
          $this.CurrentState.Locale += [ordered]@{
            Locale = $PageLanguage
            Key    = 'ReleaseNotes'
            Value  = $ReleaseNotes
          }
        } else {
          $this.Log("No ${PageLanguage} release notes for version $BuildVersion", 'Warning')
        }
      } catch {
        $this.Log("Failed to read the ${PageLanguage} release notes: ${_}", 'Warning')
      }
    }
  }

  $Status = $this.Check()
  if ($TargetVersion -and $Status -notmatch 'New|Changed|Updated') {
    # A targeted rewrite resubmits a version that is already published, which is ordered at or below
    # the tracked version, so the version comparison alone would skip the submission.
    $this.Status.AddRange([string[]]@('Changed', 'Updated'))
    $Status = $this.Status -join '|'
  }

  if ($Status -match 'New|Changed|Updated') {
    # Copyright
    # The statement is the installer's own localized text, so it is read from the installer rather
    # than carried over from the previous version: the submission pipeline moves the year of an
    # inherited statement to the current year, which would replace what the publisher states (see
    # microsoft/winget-pkgs#488216). A language the installer does not carry keeps the statement the
    # published manifests already hold, and nothing is translated here.
    $CopyrightInstaller = @($this.CurrentState.Installer | Where-Object -FilterScript { $_.InstallerUrl -and $_.Architecture -ceq 'x64' })[0]
    if (-not $CopyrightInstaller) {
      $CopyrightInstaller = @($this.CurrentState.Installer | Where-Object -FilterScript { $_.InstallerUrl })[0]
    }
    if ($CopyrightInstaller) {
      try {
        $CopyrightInstallerUrl = $CopyrightInstaller.InstallerUrl
        if (-not $this.InstallerFiles[$CopyrightInstallerUrl]) {
          $this.InstallerFiles[$CopyrightInstallerUrl] = Get-TempFile -Uri $CopyrightInstallerUrl
        }
        $CopyrightInstallerFile = $this.InstallerFiles[$CopyrightInstallerUrl]

        # The published hash is the evidence that the statement belongs to this release, so a download
        # that does not match it is not read. A release that is not published yet has no such hash.
        $CopyrightInstallerSha256 = $CopyrightInstaller['InstallerSha256']
        if ($CopyrightInstallerSha256 -and (Get-FileHash -Path $CopyrightInstallerFile -Algorithm SHA256).Hash -ine $CopyrightInstallerSha256) {
          throw "The installer downloaded from ${CopyrightInstallerUrl} does not match the SHA256 ${CopyrightInstallerSha256}"
        }

        # The installer carries one Locales/i18n.<language>.txt per language, and the STRING_INSTALLER
        # value of that file is the statement its UI shows. Only the statements the installer carries
        # are used, so nothing is translated or guessed here.
        $InstallerCopyright = [ordered]@{}
        # Reading the embedded range leaves the installer in place: expanding the SFX would copy its
        # whole payload first, which is over half a gigabyte for the full installer of this package.
        $CopyrightRange = @(Get-EmbeddedSevenZipArchiveRange -Path $CopyrightInstallerFile)[0]
        if (-not $CopyrightRange) { throw 'The installer carries no embedded 7-Zip archive' }
        $CopyrightArchiveContext = Open-InstallerArchiveRange -Path $CopyrightInstallerFile -Offset $CopyrightRange.Offset -Length $CopyrightRange.Length
        $CopyrightExtractPath = New-TempFolder
        try {
          (Export-InstallerArchiveSelection -Archive $CopyrightArchiveContext.Archive -DestinationPath $CopyrightExtractPath -Name 'Locales/i18n.*.txt' -CollisionAction Overwrite).Files | ForEach-Object {
            $CopyrightMatch = [regex]::Match([IO.File]::ReadAllText($_.FullName), '(?m)^STRING_INSTALLER[ \t]*=[ \t]*(?<Value>.*?)[ \t]*\r?$')
            if ($CopyrightMatch.Success -and $CopyrightMatch.Groups['Value'].Value.Trim()) {
              $InstallerCopyright[$_.BaseName -replace '^i18n\.', ''] = $CopyrightMatch.Groups['Value'].Value.Trim()
            }
          }
        } finally {
          Close-InstallerArchiveRange -Context $CopyrightArchiveContext
          Remove-Item -LiteralPath $CopyrightExtractPath -Recurse -Force -ErrorAction Ignore
        }

        foreach ($LocaleTag in (($TargetVersion ? @($AlignedLocale.Values) : $LiveLocale) | Sort-Object -Unique)) {
          # The installer names a language and a region, while a locale document may name only the
          # language, so an exact tag is preferred and a single regional file is the fallback.
          $Language = @($InstallerCopyright.Keys | Where-Object -FilterScript { $_ -ceq $LocaleTag })
          if ($Language.Count -eq 0) {
            $Language = @($InstallerCopyright.Keys | Where-Object -FilterScript { ($_ -split '-')[0] -ieq ($LocaleTag -split '-')[0] })
          }
          if ($Language.Count -ne 1) {
            $this.Log("The installer carries no single copyright statement for the ${LocaleTag} locale", 'Verbose')
            continue
          }
          $this.CurrentState.Locale += [ordered]@{
            Locale = $LocaleTag
            Key    = 'Copyright'
            Value  = $InstallerCopyright[$Language[0]]
          }
        }
      } catch {
        $this.Log("Failed to read the copyright statement from the installer: ${_}", 'Warning')
      }
    }
  }

  try {
    switch -Regex ($Status) {
      'New|Changed|Updated' {
        $this.Print()
        # A targeted rewrite must not replace the state that tracks the version the publisher serves.
        if (-not $TargetVersion) {
          $this.Write()
        }
      }
      'Changed|Updated' {
        if (-not $TargetVersion) {
          $this.Message()
        }
      }
      'Updated' {
        $this.Submit()
      }
    }
  } finally {
    # The staged reference is an input of this run only. Leaving it in place would point the next
    # task of this worker at a repository that publishes nothing but this package.
    if ($ReferenceRoot) {
      if ($PreviousLocalRepoPath) {
        $Global:DumplingsPreference['LocalRepoPath'] = $PreviousLocalRepoPath
      } else {
        $null = $Global:DumplingsPreference.Remove('LocalRepoPath')
      }
      Remove-Item -LiteralPath $ReferenceRoot -Recurse -Force -ErrorAction Ignore
    }
  }
