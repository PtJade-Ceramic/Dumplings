$UpstreamRepoOwner = $Global:DumplingsPreference['WinGetUpstreamRepoOwner'] ?? $this.Config['WinGetUpstreamRepoOwner'] ?? 'microsoft'
$UpstreamRepoName = $Global:DumplingsPreference['WinGetUpstreamRepoName'] ?? $this.Config['WinGetUpstreamRepoName'] ?? 'winget-pkgs'
$UpstreamRepoBranch = $Global:DumplingsPreference['WinGetUpstreamRepoBranch'] ?? $this.Config['WinGetUpstreamRepoBranch'] ?? 'master'

if ($Global:DumplingsPreference['WinGetOriginRepoOwner']) {
  $OriginRepoOwner = $Global:DumplingsPreference.WinGetOriginRepoOwner
} elseif (Test-Path -Path 'Env:\GITHUB_ACTIONS') {
  $OriginRepoOwner = $Env:GITHUB_REPOSITORY_OWNER
} else {
  throw 'The WinGet origin repository owner is unset'
}
$OriginRepoName = $Global:DumplingsPreference['WinGetOriginRepoName'] ?? $this.Config['WinGetOriginRepoName'] ?? 'winget-pkgs'

# A read is retried because the compare and contents endpoints answer 5xx while
# GitHub is under load, and an unconfirmed answer must never classify a branch.
$Read = {
  param (
    [Parameter(Mandatory)][string]$Uri,
    [switch]$AllowNotFound
  )

  for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
    try {
      return Invoke-GitHubApi -Uri $Uri
    } catch {
      $Failure = $_
      if ($AllowNotFound) {
        # Only a confirmed 404 may report that an upstream path is missing. The
        # GitHub proxy keeps the original HTTP exception as an inner exception.
        for ($Exception = $Failure.Exception; $Exception; $Exception = $Exception.InnerException) {
          $Status = if ($Exception.PSObject.Properties['Response'] -and $Exception.Response) { $Exception.Response.StatusCode } elseif ($Exception.PSObject.Properties['StatusCode']) { $Exception.StatusCode }
          if ($null -ne $Status -and [int]$Status -eq 404) { return $null }
        }
      }
      if ($Attempt -eq 3) { throw }
      Start-Sleep -Seconds (5 * $Attempt)
    }
  }
}

#region Delete published branches
$Deleted = [System.Collections.Generic.List[string]]::new()
$Kept = [System.Collections.Generic.List[string]]::new()
$Failed = [System.Collections.Generic.List[string]]::new()

$Cursor = $null
do {
  $Object1 = Invoke-GitHubApi -Uri 'https://api.github.com/graphql' -Method Post -Body @{
    query = @"
{
  repository(owner: "${OriginRepoOwner}", name: "${OriginRepoName}") {
    refs(
      refPrefix: "refs/heads/"
      orderBy: { field: TAG_COMMIT_DATE, direction: DESC }
      first: 100
      after: "$($Cursor ?? 'null')"
    ) {
      nodes {
        name
        target { oid }
        associatedPullRequests(states: [OPEN] first: 1) {
          nodes {
            number
            title
            url
          }
        }
      }
      pageInfo {
        endCursor
        hasNextPage
      }
    }
  }
}
"@
  }

  @($Object1.data.repository.refs.nodes) | Where-Object -FilterScript { $null -ne $_ } | ForEach-Object -Process {
    # The branch data is captured before any nested pipeline runs, because a
    # nested Where-Object replaces $_ for the rest of this script block.
    $BranchName = [string]$_.name
    $BranchSha = [string]$_.target.oid
    $OpenPullRequests = @($_.associatedPullRequests.nodes) | Where-Object -FilterScript { $null -ne $_ }

    if ([string]::IsNullOrWhiteSpace($BranchSha)) {
      $Failed.Add("$BranchName (the ref has no head commit)")
      $this.Log("Failed to classify the branch ${BranchName}: the ref has no head commit", 'Warning')
      return
    }
    if ((@(($Global:DumplingsPreference['WinGetOriginRepoBranch'] ?? $this.Config['WinGetOriginRepoBranch'] ?? 'master'), 'master', 'main') | Select-Object -Unique) -contains $BranchName) {
      $Kept.Add("$BranchName (protected)")
      return
    }
    # An open pull request still needs the branch it points at, even when an
    # earlier version of the same content is already on the base branch.
    if ($OpenPullRequests.Count -gt 0) {
      $Kept.Add("$BranchName (open pull request #$($OpenPullRequests[0].number))")
      return
    }

    $IsPublished = $false
    $ClassificationFailure = $null
    try {
      # The commit is already contained in the base branch, so the branch holds
      # nothing that still needs a pull request.
      $Comparison = & $Read -Uri "https://api.github.com/repos/${UpstreamRepoOwner}/${UpstreamRepoName}/compare/${UpstreamRepoBranch}...${BranchSha}"
      $IsPublished = $Comparison.status -in @('identical', 'behind')
      if (-not $IsPublished) {
        # Otherwise the branch is published once the base branch carries the
        # version directory its files belong to, whatever the local manifest
        # contents were.
        $Directories = @($Comparison.files | ForEach-Object -Process { $_.filename -replace '/[^/]+$', '' } | Sort-Object -Unique)
        if ($Directories.Count -eq 1) {
          $IsPublished = $null -ne (& $Read -Uri "https://api.github.com/repos/${UpstreamRepoOwner}/${UpstreamRepoName}/contents/$($Directories[0])?ref=${UpstreamRepoBranch}" -AllowNotFound)
        } else {
          $this.Log("The branch ${BranchName} changes $($Directories.Count) directories, so one published version cannot account for it", 'Verbose')
        }
      }
    } catch {
      $ClassificationFailure = $_.Exception.Message
    }
    if ($ClassificationFailure) {
      $Failed.Add("$BranchName ($ClassificationFailure)")
      $this.Log("Failed to classify the branch ${BranchName}: ${ClassificationFailure}", 'Warning')
      return
    }
    if (-not $IsPublished) {
      $Kept.Add($BranchName)
      return
    }

    try {
      $null = Remove-WinGetGitHubBranch -Name $BranchName -RepoOwner $OriginRepoOwner -RepoName $OriginRepoName
      $Deleted.Add($BranchName)
      $this.Log("Deleted the branch ${OriginRepoOwner}/${OriginRepoName}/${BranchName} (${BranchSha}) because ${UpstreamRepoOwner}/${UpstreamRepoName}:${UpstreamRepoBranch} already carries its content")
    } catch {
      $Failed.Add("$BranchName ($($_.Exception.Message))")
      $this.Log("Failed to delete the branch ${BranchName}: ${_}", 'Warning')
    }
  }

  $Cursor = $Object1.data.repository.refs.pageInfo.endCursor
} while ($Object1.data.repository.refs.pageInfo.hasNextPage)

$this.Log("Deleted: $($Deleted.Count); kept: $($Kept.Count); failed: $($Failed.Count)")
$Kept | ForEach-Object {
  $this.Log("Kept the branch $_", 'Verbose')
}
#endregion
