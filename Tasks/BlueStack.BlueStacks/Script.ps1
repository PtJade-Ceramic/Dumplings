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

# Release notes
# A normal run reads the notes of the build the download article serves, while a targeted rewrite
# reads the notes of the build it rewrites, whose release line the article below documents; that run
# strips the published locale documents of their notes before the delivery, so its notes are filled
# for every language the article documents.
if ($TargetVersion) {
  $NotesMajorMinorVersion = ($TargetVersion -split '\.')[0..1] -join '.'
  $NotesBuildVersion = ($TargetVersion -split '\.')[0..2] -join '.'
  $NotesMissingLogLevel = 'Verbose'
} else {
  $NotesMajorMinorVersion = $MajorMinorVersion
  $NotesBuildVersion = $BuildVersion
  $NotesMissingLogLevel = 'Warning'
}

try {
  # The release-notes article names the languages the publisher serves and carries the notes of each
  # of them, so its alternates are the language set of the release line it documents. A page states
  # the language it is written in; a language the publisher has not translated answers with the
  # English page, which is left out because the page disagrees with its own hreflang. The article of
  # the rewritten release line is used, falling back to the language set of the download article when
  # the publisher lists no article for that line.
  # The release-notes section lists one article per release line, so the article is looked up by the
  # heading the publisher gives it.
  $NotesArticleLink = (Get-BlueStacksPageContent -Uri 'https://support.bluestacks.com/hc/en-us/sections/360012290292' | ConvertFrom-Html).SelectNodes("//ul[contains(@class, 'article-list')]//a") |
    Where-Object -FilterScript { ($_.InnerText -replace '\s+', ' ').Trim() -ceq "BlueStacks ${NotesMajorMinorVersion} Release Notes" } |
    Select-Object -First 1
  $NotesArticle = if ($NotesArticleLink) {
    Get-BlueStacksPageContent -Uri (Join-Uri 'https://support.bluestacks.com/' $NotesArticleLink.Attributes['href'].Value) | ConvertFrom-Html
  }
  if (-not $NotesArticle) {
    $this.Log("The release-notes section lists no article for BlueStacks $NotesMajorMinorVersion", 'Warning')
  }
  $Alternates = @(
    ($NotesArticle ?? $DownloadArticle).SelectNodes('//link[@rel="alternate"][@hreflang][@href]') |
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

        # Only a page of the release-notes article supplies notes; the download article it falls
        # back to describes the installer of the line rather than the build being rewritten.
        [pscustomobject]@{
          Locale  = $PageLanguage
          Article = $NotesArticle ? $LocaleArticle : $null
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

# The notes are keyed by the locale of the document that delivers them.
$Notes = [ordered]@{}
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
  # A locale document is inherited from the reference, so a language the published set does not
  # declare is added by writing its identity into the staged reference. The copyright statement and
  # the notes below fill it, and the submission then delivers it like any other document.
  $AddedLocale = @($LiveLocale | Where-Object -FilterScript { $AlignedLocale.Values -cnotcontains $_ })
  $AddedLocale | ForEach-Object -Process {
    $AddedLocalePath = Join-Path $ReferenceVersionPath "BlueStack.BlueStacks.locale.${_}.yaml"
    $AddedLocaleContent = "PackageIdentifier: BlueStack.BlueStacks`nPackageVersion: ${TargetVersion}`nPackageLocale: ${_}`nManifestType: locale`nManifestVersion: $([string]$PublishedModel.ManifestVersion)`n"
    [IO.File]::WriteAllText($AddedLocalePath, $AddedLocaleContent)
    $this.Log("Adding the ${_} locale document the published set does not declare", 'Info')
  }

  # The inherited locale documents are stripped of their notes before the delivery, so the notes of
  # a language the article documents are read for every language that has none yet, while the notes
  # the published set already states are kept as they are.
  $PublishedNotes.Keys | ForEach-Object -Process { $Notes[$AlignedLocale[$_]] = $PublishedNotes[$_] }
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
}

# Release notes
$ReleaseTime = $null
foreach ($Page in $LocalizedPages) {
  # Only a page of the release-notes article supplies notes, and notes the set already holds keep
  # the language of the locale document they belong to.
  if (-not $Page.Article -or $Notes.Contains($Page.Locale)) { continue }

  try {
    # The notes of the build start at its heading and run to the next heading or horizontal rule,
    # which is where the publisher closes an entry before naming the next build in a paragraph.
    $Note = $null
    $TitleNode = @($Page.Article.SelectNodes("//div[@itemprop='articleBody']//*[self::h3 or self::h4]") ?? @()) |
      Where-Object -FilterScript { ($_.InnerText -replace '\s+', ' ') -like "*$NotesBuildVersion*" } |
      Select-Object -First 1
    if ($TitleNode) {
      $ReleaseNotesNodes = @(
        for ($Node = $TitleNode.NextSibling; $Node; $Node = $Node.NextSibling) {
          if ($Node.Name -cin @('h1', 'h2', 'h3', 'h4', 'hr')) { break }
          # A blank node, or the download button an entry repeats, is not part of the notes. The
          # button is a classed link on some lines and a plain installer link on others.
          $NodeLinks = @($Node.SelectNodes('.//a[@href]') ?? @())
          if (
            [string]::IsNullOrWhiteSpace($Node.InnerText) -or
            @($NodeLinks | Where-Object -FilterScript { $_.GetAttributeValue('href', '') -match '\.exe(\?|$)' }).Count -gt 0
          ) { continue }
          $Node
        }
      )

      # An entry closes with a localized "released on" line carrying a calendar year. It supplies
      # the release date and is not part of the notes.
      $NoteReleaseTime = $null
      if ($ReleaseNotesNodes.Count -gt 0) {
        # The closing line states the date in the language of the page, so the month comes from
        # that culture's own month names while the day and the year come from the numbers of the
        # line. The line is not handed to DateTime.TryParse: the label around the date differs per
        # language, and the culture's calendar is applied silently, so the Thai page reads its 2026
        # as a Buddhist year and answers a date three centuries earlier. The loop below runs once
        # and only gives the guards a way to leave the parse.
        $Line = ($ReleaseNotesNodes[-1].InnerText -replace '\s+', ' ').Trim()
        $ReleasedDate = $null
        do {
          # An entry whose last paragraph is notes rather than a date line is left to the notes.
          if ($Line.Length -gt 80) { break }

          try {
            $Culture = [System.Globalization.CultureInfo]::GetCultureInfo($Page.Locale)
          } catch {
            break
          }
          $Format = $Culture.DateTimeFormat

          $Numbers = @(
            [regex]::Matches($Line, '\d+') | ForEach-Object -Process {
              $Value = 0
              if ([int]::TryParse($_.Value, [ref]$Value)) {
                [pscustomobject]@{ Start = $_.Index; End = $_.Index + $_.Length; Value = $Value }
              }
            }
          )

          # The longest matching name wins, so a month whose name carries another month's name,
          # such as the numeric December and February names of Japanese, resolves to the longer one. The genitive names are included
          # because a date writes the month in that form in several languages.
          $MonthMatch = @(
            for ($MonthIndex = 1; $MonthIndex -le 12; $MonthIndex++) {
              'MonthNames', 'MonthGenitiveNames', 'AbbreviatedMonthNames', 'AbbreviatedMonthGenitiveNames' | ForEach-Object {
                $Name = $Format.$_[$MonthIndex - 1]
                if ([string]::IsNullOrWhiteSpace($Name)) { continue }
                $Start = $Culture.CompareInfo.IndexOf($Line, $Name, [System.Globalization.CompareOptions]::IgnoreCase)
                if ($Start -lt 0) { continue }
                [pscustomobject]@{
                  Month = $MonthIndex
                  Start = $Start
                  End   = $Start + $Name.Length
                }
              }
            }
          ) | Sort-Object -Property { $_.End - $_.Start } -Descending | Select-Object -First 1

          # A number the month name itself writes, such as the 2 of the numeric February name, is not part of the date.
          $Numbers = @($Numbers | Where-Object -FilterScript { -not $MonthMatch -or $_.End -le $MonthMatch.Start -or $_.Start -ge $MonthMatch.End })
          $Years = @($Numbers | Where-Object -FilterScript { $_.Value -ge 1900 -and $_.Value -le 2100 })
          if ($Years.Count -ne 1) { break }
          $Year = $Years[0].Value
          $Remaining = @($Numbers | Where-Object -FilterScript { $_.Value -ne $Year })

          if ($MonthMatch) {
            $Days = @($Remaining | Where-Object -FilterScript { $_.Value -ge 1 -and $_.Value -le 31 })
            if ($Days.Count -ne 1) { break }
            $Month, $Day = $MonthMatch.Month, $Days[0].Value
          } else {
            # Without a spelled month the line writes three numbers, and the culture's short date
            # pattern says whether it writes the month or the day first.
            if ($Remaining.Count -ne 2) { break }
            if (($Format.ShortDatePattern -replace '[^Md]', '')[0] -eq 'M') {
              $Month, $Day = $Remaining[0].Value, $Remaining[1].Value
            } else {
              $Month, $Day = $Remaining[1].Value, $Remaining[0].Value
            }
            if ($Month -lt 1 -or $Month -gt 12 -or $Day -lt 1 -or $Day -gt 31) { $Month, $Day = $Day, $Month }
          }

          try {
            $ReleasedDate = [datetime]::new($Year, $Month, $Day).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
          } catch {
            # A day the culture's calendar does not have is not an attributable date.
            $ReleasedDate = $null
          }
        } while ($false)
        if ($ReleasedDate) {
          $NoteReleaseTime = $ReleasedDate
          $ReleaseNotesNodes = @($ReleaseNotesNodes | Select-Object -SkipLast 1)
        }
      }

      $ReleaseNotes = $ReleaseNotesNodes | Get-TextContent | Format-Text
      # The schema bounds the field, so an entry longer than that is not attributable to one build.
      if ($ReleaseNotes -and $ReleaseNotes.Length -le 10000) {
        $Note = [pscustomobject]@{
          ReleaseNotes = $ReleaseNotes
          ReleaseTime  = $NoteReleaseTime
        }
      }
    }
  } catch {
    $this.Log("Failed to read the $($Page.Locale) release notes: ${_}", 'Warning')
    continue
  }
  if (-not $Note -or -not $Note.ReleaseNotes) {
    $this.Log("The release-notes article states no $NotesBuildVersion notes in $($Page.Locale)", $NotesMissingLogLevel)
    continue
  }

  $Notes[$Page.Locale] = $Note.ReleaseNotes
  # Every locale states the same release date, so the first one is kept.
  if (-not $ReleaseTime -and $Note.ReleaseTime) { $ReleaseTime = $Note.ReleaseTime }
}

if (-not $this.CurrentState['ReleaseTime'] -and $ReleaseTime) {
  $this.CurrentState.ReleaseTime = $ReleaseTime
}
$Notes.Keys | ForEach-Object -Process {
  $this.CurrentState.Locale += [ordered]@{
    Locale = $_
    Key    = 'ReleaseNotes'
    Value  = $Notes[$_]
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
  # The locale documents this run authors: the published set of a targeted rewrite, and every
  # language the download article serves otherwise.
  $AuthoredTags = $TargetVersion ? @(@($AlignedLocale.Values) + $AddedLocale | Sort-Object -Unique) : $LiveLocale

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
        # The full installer of the 5.x line nests the installer that carries the locales, so the
        # nested executable is read when the outer archive holds no locale file.
        $CopyrightLocaleFile = @((Export-InstallerArchiveSelection -Archive $CopyrightArchiveContext.Archive -DestinationPath $CopyrightExtractPath -Name 'Locales/i18n.*.txt' -CollisionAction Overwrite).Files)
        if ($CopyrightLocaleFile.Count -eq 0) {
          $CopyrightNestedEntry = @($CopyrightArchiveContext.Archive.Entries | Where-Object -FilterScript { -not $_.IsDirectory -and $_.Key -match '^[^/]+\.exe$' })
          if ($CopyrightNestedEntry.Count -ne 1) { throw 'The installer carries no locale file' }
          $CopyrightNestedFile = @((Export-InstallerArchiveSelection -Archive $CopyrightArchiveContext.Archive -DestinationPath $CopyrightExtractPath -Name $CopyrightNestedEntry[0].Key -CollisionAction Overwrite).Files)[0]
          $CopyrightNestedRange = @(Get-EmbeddedSevenZipArchiveRange -Path $CopyrightNestedFile.FullName)[0]
          if (-not $CopyrightNestedRange) { throw 'The nested installer carries no embedded 7-Zip archive' }
          $CopyrightNestedContext = Open-InstallerArchiveRange -Path $CopyrightNestedFile.FullName -Offset $CopyrightNestedRange.Offset -Length $CopyrightNestedRange.Length
          try {
            $CopyrightLocaleFile = @((Export-InstallerArchiveSelection -Archive $CopyrightNestedContext.Archive -DestinationPath (Join-Path $CopyrightExtractPath 'nested') -Name 'Locales/i18n.*.txt' -CollisionAction Overwrite).Files)
          } finally {
            Close-InstallerArchiveRange -Context $CopyrightNestedContext
          }
        }
        $CopyrightLocaleFile | ForEach-Object {
          $CopyrightMatch = [regex]::Match([IO.File]::ReadAllText($_.FullName), '(?m)^STRING_INSTALLER[ \t]*=[ \t]*(?<Value>.*?)[ \t]*\r?$')
          if ($CopyrightMatch.Success -and $CopyrightMatch.Groups['Value'].Value.Trim()) {
            $InstallerCopyright[$_.BaseName -replace '^i18n\.', ''] = $CopyrightMatch.Groups['Value'].Value.Trim()
          }
        }
      } finally {
        Close-InstallerArchiveRange -Context $CopyrightArchiveContext
        Remove-Item -LiteralPath $CopyrightExtractPath -Recurse -Force -ErrorAction Ignore
      }

      foreach ($LocaleTag in $AuthoredTags) {
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

  # Publisher metadata
  # The publisher states the product tagline of each language on the marketing site, and the download
  # page lists one locale of it per language. The localized download page of a language is not
  # translated, so the tagline is read from the landing page next to it, which declares the language
  # it is written in; the English page is the download page itself, because the site answers the
  # default locale with its Chinese landing page. The other fields do not depend on the language.
  $MarketingDownloadPage = Get-BlueStacksPageContent -Uri 'https://www.bluestacks.com/download.html' | ConvertFrom-Html
  $MarketingTagline = @(
    [pscustomobject]@{
      Language    = $MarketingDownloadPage.SelectSingleNode('//html')?.GetAttributeValue('lang', '')
      Description = [System.Net.WebUtility]::HtmlDecode($MarketingDownloadPage.SelectSingleNode('//meta[@name="description"]')?.GetAttributeValue('content', '' ) ?? '').Trim()
    }
    $MarketingDownloadPage.SelectNodes('//link[@rel="alternate"][@href][@hreflang]') | Where-Object -FilterScript { $_.GetAttributeValue('hreflang', '') -cne 'x-default' } | ForEach-Object {
      $MarketingUrl = $_.GetAttributeValue('href', '') -replace '/download\.html$', '/index.html'
      try {
        $MarketingPage = Get-BlueStacksPageContent -Uri $MarketingUrl | ConvertFrom-Html
        $MarketingLanguage = $MarketingPage.SelectSingleNode('//html')?.GetAttributeValue('lang', '')
        $MarketingDescription = [System.Net.WebUtility]::HtmlDecode($MarketingPage.SelectSingleNode('//meta[@name="description"]')?.GetAttributeValue('content', '') ?? '').Trim()
        if ([string]::IsNullOrWhiteSpace($MarketingLanguage) -or [string]::IsNullOrWhiteSpace($MarketingDescription)) { return }
        [pscustomobject]@{
          Language    = $MarketingLanguage
          Description = $MarketingDescription
        }
      } catch {
        $this.Log("Failed to read the marketing page ${MarketingUrl}: ${_}", 'Warning')
      }
    }
  )

  $PublisherLocale = [ordered]@{
    Publisher           = 'BlueStack Systems, Inc.'
    PublisherUrl        = 'https://www.bluestacks.com/'
    PublisherSupportUrl = 'https://support.bluestacks.com/'
    PrivacyUrl          = 'https://www.bluestacks.com/terms-and-privacy.html#privacy'
    Author              = 'BlueStack Systems, Inc.'
    PackageName         = 'BlueStacks'
    PackageUrl          = 'https://www.bluestacks.com/download.html'
    License             = 'Proprietary'
    LicenseUrl          = 'https://www.bluestacks.com/terms-and-privacy.html#terms'
    CopyrightUrl        = 'https://www.bluestacks.com/copyright-dispute-policy.html'
  }
  $PublisherLocale.Keys | ForEach-Object {
    $this.CurrentState.Locale += [ordered]@{
      Key   = $_
      Value = $PublisherLocale[$_]
    }
  }

  foreach ($AuthoredTag in $AuthoredTags) {
    # The marketing page names a script or a region where a locale document names only the
    # language, so an exact tag is preferred and a single language is the fallback.
    $Tagline = @($MarketingTagline | Where-Object -FilterScript { $_.Language -ieq $AuthoredTag })
    if ($Tagline.Count -eq 0) {
      $Tagline = @($MarketingTagline | Where-Object -FilterScript { ($_.Language -split '-')[0] -ieq ($AuthoredTag -split '-')[0] })
    }
    if ($Tagline.Count -ne 1) {
      $this.Log("The marketing site states no single tagline for the ${AuthoredTag} locale", 'Verbose')
      continue
    }
    'ShortDescription', 'Description' | ForEach-Object {
      $this.CurrentState.Locale += [ordered]@{
        Locale = $AuthoredTag
        Key    = $_
        Value  = $Tagline[0].Description
      }
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
