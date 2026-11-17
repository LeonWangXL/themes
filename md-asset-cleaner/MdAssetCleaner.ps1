param([switch]$SelfTest)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ImageLinks([string]$Content) {
    $links = [System.Collections.Generic.List[string]]::new()

    foreach ($match in [regex]::Matches($Content, '!\[[^\]]*\]\(\s*(?:<(?<angle>[^>]+)>|(?<plain>[^\s\)]+))', 'IgnoreCase')) {
        $value = if ($match.Groups['angle'].Success) { $match.Groups['angle'].Value } else { $match.Groups['plain'].Value }
        $links.Add($value)
    }
    foreach ($match in [regex]::Matches($Content, '<img\b[^>]*\bsrc\s*=\s*(?:"(?<dq>[^"]+)"|''(?<sq>[^'']+)''|(?<bare>[^\s>]+))', 'IgnoreCase')) {
        foreach ($name in 'dq', 'sq', 'bare') {
            if ($match.Groups[$name].Success) { $links.Add($match.Groups[$name].Value); break }
        }
    }

    $definitions = @{}
    foreach ($match in [regex]::Matches($Content, '(?m)^\s{0,3}\[(?<id>[^\]]+)\]:\s*(?:<(?<angle>[^>]+)>|(?<plain>\S+))')) {
        $value = if ($match.Groups['angle'].Success) { $match.Groups['angle'].Value } else { $match.Groups['plain'].Value }
        $definitions[$match.Groups['id'].Value.Trim().ToLowerInvariant()] = $value
    }
    foreach ($match in [regex]::Matches($Content, '!\[(?<alt>[^\]]*)\]\[(?<id>[^\]]*)\]')) {
        $id = $match.Groups['id'].Value
        if ([string]::IsNullOrWhiteSpace($id)) { $id = $match.Groups['alt'].Value }
        $key = $id.Trim().ToLowerInvariant()
        if ($definitions.ContainsKey($key)) { $links.Add($definitions[$key]) }
    }

    return $links
}

function Resolve-ImagePath([string]$Link, [string]$MarkdownPath, [string]$ImageDirectory) {
    $markdownDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($MarkdownPath))
    $imageRoot = [IO.Path]::GetFullPath($ImageDirectory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $Link = [Net.WebUtility]::HtmlDecode($Link.Trim())
    if ($Link -match '^(?://|#)') { return $null }
    if ($Link -match '^[a-z][a-z0-9+.-]*:' -and $Link -notmatch '^[a-zA-Z]:[/\\]') {
        try {
            $uri = [Uri]$Link
            if (-not $uri.IsFile) { return $null }
            $Link = $uri.LocalPath
        } catch { return $null }
    } else {
        $Link = ($Link -split '[?#]', 2)[0]
        try { $Link = [Uri]::UnescapeDataString($Link) } catch { return $null }
    }
    try {
        if ([IO.Path]::IsPathRooted($Link)) { $path = [IO.Path]::GetFullPath($Link) }
        else { $path = [IO.Path]::GetFullPath([IO.Path]::Combine($markdownDirectory, $Link.Replace('/', '\'))) }
    } catch { return $null }
    if ($path.StartsWith($imageRoot, [StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists($path)) {
        return $path
    }
    return $null
}

function Resolve-ImagePaths([string]$Content, [string]$MarkdownPath, [string]$ImageDirectory) {
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($link in Get-ImageLinks $Content) {
        $path = Resolve-ImagePath $link $MarkdownPath $ImageDirectory
        if ($path) { [void]$paths.Add($path) }
    }
    return $paths
}

function Get-RelativeImageLink([string]$MarkdownPath, [string]$ImagePath) {
    $markdownDirectory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($MarkdownPath))
    if ([IO.Path]::GetPathRoot($markdownDirectory) -ne [IO.Path]::GetPathRoot($ImagePath)) {
        return ([Uri]$ImagePath).AbsoluteUri
    }
    $baseUri = [Uri]($markdownDirectory.TrimEnd('\') + '\')
    return $baseUri.MakeRelativeUri([Uri]$ImagePath).OriginalString.Replace('(', '%28').Replace(')', '%29')
}

function Rewrite-ImageLinks([string]$Content, [string]$SourceMarkdown, [string]$TargetMarkdown, [string]$ImageDirectory, $ImageMap) {
    $rewrite = {
        param([string]$link)
        $source = Resolve-ImagePath $link $SourceMarkdown $ImageDirectory
        if (-not $source -or -not $ImageMap.ContainsKey($source)) { return $null }
        return Get-RelativeImageLink $TargetMarkdown $ImageMap[$source]
    }

    $inline = [regex]::new('(?<prefix>!\[[^\]]*\]\(\s*)(?:<(?<angle>[^>]+)>|(?<plain>[^\s\)]+))', 'IgnoreCase')
    $Content = $inline.Replace($Content, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $link = if ($match.Groups['angle'].Success) { $match.Groups['angle'].Value } else { $match.Groups['plain'].Value }
        $newLink = & $rewrite $link
        if (-not $newLink) { return $match.Value }
        $value = if ($match.Groups['angle'].Success) { "<$newLink>" } else { $newLink }
        return $match.Groups['prefix'].Value + $value
    })

    $html = [regex]::new('(?<prefix><img\b[^>]*?\bsrc\s*=\s*)(?:"(?<dq>[^"]+)"|''(?<sq>[^'']+)''|(?<bare>[^\s>]+))', 'IgnoreCase')
    $Content = $html.Replace($Content, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        foreach ($name in 'dq', 'sq', 'bare') { if ($match.Groups[$name].Success) { $link = $match.Groups[$name].Value; break } }
        $newLink = & $rewrite $link
        if (-not $newLink) { return $match.Value }
        if ($match.Groups['dq'].Success) { $newLink = '"' + $newLink + '"' }
        elseif ($match.Groups['sq'].Success) { $newLink = "'" + $newLink + "'" }
        return $match.Groups['prefix'].Value + $newLink
    })

    $imageIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($Content, '!\[(?<alt>[^\]]*)\]\[(?<id>[^\]]*)\]')) {
        $id = if ($match.Groups['id'].Value) { $match.Groups['id'].Value } else { $match.Groups['alt'].Value }
        [void]$imageIds.Add($id.Trim())
    }
    $definition = [regex]::new('(?m)^(?<prefix>\s{0,3}\[(?<id>[^\]]+)\]:\s*)(?:<(?<angle>[^>]+)>|(?<plain>\S+))')
    return $definition.Replace($Content, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if (-not $imageIds.Contains($match.Groups['id'].Value.Trim())) { return $match.Value }
        $link = if ($match.Groups['angle'].Success) { $match.Groups['angle'].Value } else { $match.Groups['plain'].Value }
        $newLink = & $rewrite $link
        if (-not $newLink) { return $match.Value }
        $value = if ($match.Groups['angle'].Success) { "<$newLink>" } else { $newLink }
        return $match.Groups['prefix'].Value + $value
    })
}

function Get-DeletionPlan([string[]]$MarkdownPaths, [string]$ImageDirectory, [string]$ScanRoot) {
    $documents = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $referenced = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $shared = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($markdownPath in $MarkdownPaths) {
        $fullPath = [IO.Path]::GetFullPath($markdownPath)
        [void]$documents.Add($fullPath)
        foreach ($path in Resolve-ImagePaths ([IO.File]::ReadAllText($fullPath)) $fullPath $ImageDirectory) {
            [void]$referenced.Add($path)
        }
    }

    foreach ($other in Get-ChildItem -LiteralPath $ScanRoot -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue) {
        if ($documents.Contains($other.FullName)) { continue }
        try {
            foreach ($path in Resolve-ImagePaths ([IO.File]::ReadAllText($other.FullName)) $other.FullName $ImageDirectory) {
                if ($referenced.Contains($path)) { [void]$shared.Add($path) }
            }
        } catch { }
    }

    [pscustomobject]@{
        Documents = @($documents | Sort-Object)
        Images = @($referenced | Sort-Object)
        Delete = @($referenced | Where-Object { -not $shared.Contains($_) } | Sort-Object)
        Keep   = @($shared | Sort-Object)
    }
}

function Get-FreeDestination([string]$SourcePath, [string]$TargetDirectory, $Reserved) {
    $name = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $extension = [IO.Path]::GetExtension($SourcePath)
    $candidate = [IO.Path]::Combine($TargetDirectory, [IO.Path]::GetFileName($SourcePath))
    $number = 1
    while ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate) -or $Reserved.Contains($candidate)) {
        $candidate = [IO.Path]::Combine($TargetDirectory, "$name ($number)$extension")
        $number++
    }
    [void]$Reserved.Add($candidate)
    return $candidate
}

function Read-TextFile([string]$Path) {
    $reader = [IO.StreamReader]::new($Path, $true)
    try {
        $content = $reader.ReadToEnd()
        return [pscustomobject]@{ Content = $content; Encoding = $reader.CurrentEncoding }
    } finally { $reader.Dispose() }
}

function Invoke-MoveBundle($Plan, [string]$ImageDirectory, [string]$TargetMarkdownDirectory, [string]$TargetImageDirectory) {
    $targetMarkdownRoot = [IO.Path]::GetFullPath($TargetMarkdownDirectory)
    $targetImageRoot = [IO.Path]::GetFullPath($TargetImageDirectory)
    $documentMap = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $imageMap = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $reserved = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $documentTargets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($source in $Plan.Documents) {
        $target = [IO.Path]::Combine($targetMarkdownRoot, [IO.Path]::GetFileName($source))
        if ($source -eq $target) { throw "Markdown 已在目标目录中：$source" }
        if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target) -or $documentTargets.Contains($target)) { throw "目标 Markdown 已存在：$target" }
        [void]$documentTargets.Add($target)
        $documentMap.Add($source, $target)
    }
    foreach ($source in $Plan.Images) {
        $samePath = [IO.Path]::Combine($targetImageRoot, [IO.Path]::GetFileName($source))
        if ($source -eq $samePath) { $target = $source; [void]$reserved.Add($target) }
        else { $target = Get-FreeDestination $source $targetImageRoot $reserved }
        $imageMap.Add($source, $target)
    }

    $created = [System.Collections.Generic.List[string]]::new()
    $createdImageDirectory = $false
    $committed = $false
    try {
        if ($Plan.Images.Count -gt 0 -and -not [IO.Directory]::Exists($targetImageRoot)) {
            [void][IO.Directory]::CreateDirectory($targetImageRoot)
            $createdImageDirectory = $true
        }
        foreach ($source in $Plan.Images) {
            $target = $imageMap[$source]
            if ($source -ne $target) { [IO.File]::Copy($source, $target); $created.Add($target) }
        }
        foreach ($source in $Plan.Documents) {
            $target = $documentMap[$source]
            $text = Read-TextFile $source
            $content = Rewrite-ImageLinks $text.Content $source $target $ImageDirectory $imageMap
            [IO.File]::WriteAllText($target, $content, $text.Encoding)
            $created.Add($target)

            $resolved = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($path in Resolve-ImagePaths $content $target $targetImageRoot) { [void]$resolved.Add($path) }
            foreach ($sourceImage in Resolve-ImagePaths $text.Content $source $ImageDirectory) {
                if (-not $resolved.Contains($imageMap[$sourceImage])) { throw "移动后图片引用校验失败：$sourceImage" }
            }
        }
        $committed = $true
        foreach ($source in $Plan.Documents) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($source, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
        foreach ($source in $Plan.Delete) {
            if ($source -ne $imageMap[$source]) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($source, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
            }
        }
        $sharedCopies = @($Plan.Keep | Where-Object { $_ -ne $imageMap[$_] }).Count
        return [pscustomobject]@{ Documents = $Plan.Documents.Count; Images = $Plan.Images.Count; SharedCopies = $sharedCopies }
    } catch {
        if (-not $committed) {
            foreach ($path in $created) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
            if ($createdImageDirectory -and [IO.Directory]::Exists($targetImageRoot) -and (Get-ChildItem -LiteralPath $targetImageRoot -Force).Count -eq 0) {
                [IO.Directory]::Delete($targetImageRoot)
            }
        }
        throw
    }
}

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Self-test failed: $Message" }
}

function Invoke-SelfTest {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('md-asset-cleaner-' + [guid]::NewGuid())
    $assets = Join-Path $testRoot 'assets'
    try {
        [void](New-Item -ItemType Directory -Path $assets)
        [IO.File]::WriteAllText((Join-Path $assets 'a b.png'), 'x')
        [IO.File]::WriteAllText((Join-Path $assets 'abs.png'), 'x')
        [IO.File]::WriteAllText((Join-Path $assets 'batch.png'), 'x')
        [IO.File]::WriteAllText((Join-Path $assets 'ref.png'), 'x')
        [IO.File]::WriteAllText((Join-Path $assets 'shared.jpg'), 'x')
        [IO.File]::WriteAllText((Join-Path $testRoot 'outside.png'), 'x')
        $main = Join-Path $testRoot 'main.md'
        $batch = Join-Path $testRoot 'batch.md'
        $other = Join-Path $testRoot 'other.md'
        $absoluteImage = Join-Path $assets 'abs.png'
        [IO.File]::WriteAllText($main, "![a](assets/a%20b.png)`n![abs]($absoluteImage)`n<img src=`"assets/shared.jpg`">`n![ref][r]`n[r]: assets/ref.png`n![x](outside.png)")
        [IO.File]::WriteAllText($batch, '![batch](assets/batch.png)')
        [IO.File]::WriteAllText($other, '![shared](assets/shared.jpg)')
        $plan = Get-DeletionPlan -MarkdownPaths @($main, $batch) -ImageDirectory $assets -ScanRoot $testRoot
        Assert ($plan.Documents.Count -eq 2) 'batch document selection'
        Assert ($plan.Delete.Count -eq 4 -and ($plan.Delete | Where-Object { $_.EndsWith('batch.png') })) 'batch image detection'
        Assert ($plan.Keep.Count -eq 1 -and $plan.Keep[0].EndsWith('shared.jpg')) 'shared image protection'
        $map = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $plan.Images) { $map[$path] = Join-Path (Join-Path $testRoot 'destination\images') ([IO.Path]::GetFileName($path)) }
        $rewritten = Rewrite-ImageLinks ([IO.File]::ReadAllText($main)) $main (Join-Path $testRoot 'destination\main.md') $assets $map
        Assert ($rewritten.Contains('images/a%20b.png') -and $rewritten.Contains('src="images/shared.jpg"') -and $rewritten.Contains('[r]: images/ref.png')) 'moved link rewriting'
        'Self-test passed.'
    } finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    }
}

if ($SelfTest) { Invoke-SelfTest; exit }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[Windows.Forms.Application]::EnableVisualStyles()

$form = [Windows.Forms.Form]@{
    Text = 'Markdown 文件与图片管理器'
    StartPosition = 'CenterScreen'
    ClientSize = [Drawing.Size]::new(760, 665)
    MinimumSize = [Drawing.Size]::new(700, 615)
    Font = [Drawing.Font]::new('Microsoft YaHei UI', 9)
}

$mdLabel = [Windows.Forms.Label]@{ Text = 'Markdown 文件（可多选）'; Location = [Drawing.Point]::new(16, 20); AutoSize = $true }
$mdBox = [Windows.Forms.TextBox]@{ Location = [Drawing.Point]::new(16, 43); Size = [Drawing.Size]::new(620, 28); ReadOnly = $true; Anchor = 'Top,Left,Right' }
$mdButton = [Windows.Forms.Button]@{ Text = '选择...'; Location = [Drawing.Point]::new(650, 41); Size = [Drawing.Size]::new(90, 30); Anchor = 'Top,Right' }
$dirLabel = [Windows.Forms.Label]@{ Text = '图片目录（只会处理此目录内的图片）'; Location = [Drawing.Point]::new(16, 85); AutoSize = $true }
$dirBox = [Windows.Forms.TextBox]@{ Location = [Drawing.Point]::new(16, 108); Size = [Drawing.Size]::new(620, 28); ReadOnly = $true; Anchor = 'Top,Left,Right' }
$dirButton = [Windows.Forms.Button]@{ Text = '选择...'; Location = [Drawing.Point]::new(650, 106); Size = [Drawing.Size]::new(90, 30); Anchor = 'Top,Right' }
$scanLabel = [Windows.Forms.Label]@{ Text = 'Markdown 扫描根目录（在此范围检查共用图片）'; Location = [Drawing.Point]::new(16, 150); AutoSize = $true }
$scanBox = [Windows.Forms.TextBox]@{ Location = [Drawing.Point]::new(16, 173); Size = [Drawing.Size]::new(620, 28); ReadOnly = $true; Anchor = 'Top,Left,Right' }
$scanButton = [Windows.Forms.Button]@{ Text = '选择...'; Location = [Drawing.Point]::new(650, 171); Size = [Drawing.Size]::new(90, 30); Anchor = 'Top,Right' }
$targetMdLabel = [Windows.Forms.Label]@{ Text = '移动到 Markdown 目录'; Location = [Drawing.Point]::new(16, 215); AutoSize = $true }
$targetMdBox = [Windows.Forms.TextBox]@{ Location = [Drawing.Point]::new(16, 238); Size = [Drawing.Size]::new(620, 28); ReadOnly = $true; Anchor = 'Top,Left,Right' }
$targetMdButton = [Windows.Forms.Button]@{ Text = '选择...'; Location = [Drawing.Point]::new(650, 236); Size = [Drawing.Size]::new(90, 30); Anchor = 'Top,Right' }
$targetImgLabel = [Windows.Forms.Label]@{ Text = '移动到图片目录（不存在时自动创建）'; Location = [Drawing.Point]::new(16, 280); AutoSize = $true }
$targetImgBox = [Windows.Forms.TextBox]@{ Location = [Drawing.Point]::new(16, 303); Size = [Drawing.Size]::new(620, 28); ReadOnly = $true; Anchor = 'Top,Left,Right' }
$targetImgButton = [Windows.Forms.Button]@{ Text = '选择...'; Location = [Drawing.Point]::new(650, 301); Size = [Drawing.Size]::new(90, 30); Anchor = 'Top,Right' }
$resultLabel = [Windows.Forms.Label]@{ Text = '扫描结果'; Location = [Drawing.Point]::new(16, 346); AutoSize = $true }
$list = [Windows.Forms.ListBox]@{ Location = [Drawing.Point]::new(16, 369); Size = [Drawing.Size]::new(724, 210); Anchor = 'Top,Bottom,Left,Right'; HorizontalScrollbar = $true }
$status = [Windows.Forms.Label]@{ Text = '请选择 Markdown 文件。'; Location = [Drawing.Point]::new(16, 605); AutoSize = $true; Anchor = 'Bottom,Left' }
$deleteButton = [Windows.Forms.Button]@{ Text = '删除到回收站'; Location = [Drawing.Point]::new(485, 599); Size = [Drawing.Size]::new(125, 36); Anchor = 'Bottom,Right'; Enabled = $false }
$moveButton = [Windows.Forms.Button]@{ Text = '移动文件'; Location = [Drawing.Point]::new(620, 599); Size = [Drawing.Size]::new(120, 36); Anchor = 'Bottom,Right'; Enabled = $false }
$form.Controls.AddRange(@($mdLabel, $mdBox, $mdButton, $dirLabel, $dirBox, $dirButton, $scanLabel, $scanBox, $scanButton, $targetMdLabel, $targetMdBox, $targetMdButton, $targetImgLabel, $targetImgBox, $targetImgButton, $resultLabel, $list, $status, $deleteButton, $moveButton))

$script:plan = $null
$script:markdownPaths = @()
function Refresh-Plan {
    $list.Items.Clear()
    $deleteButton.Enabled = $false
    $moveButton.Enabled = $false
    if ($script:markdownPaths.Count -eq 0 -or @($script:markdownPaths | Where-Object { -not [IO.File]::Exists($_) }).Count -gt 0 -or -not [IO.Directory]::Exists($dirBox.Text) -or -not [IO.Directory]::Exists($scanBox.Text)) {
        $status.Text = '请选择有效的 Markdown 文件、图片目录和扫描根目录。'
        return
    }
    try {
        $script:plan = Get-DeletionPlan -MarkdownPaths $script:markdownPaths -ImageDirectory $dirBox.Text -ScanRoot $scanBox.Text
        foreach ($path in $script:plan.Documents) { [void]$list.Items.Add("Markdown：$path") }
        foreach ($path in $script:plan.Delete) { [void]$list.Items.Add("独占图片：$path") }
        foreach ($path in $script:plan.Keep) { [void]$list.Items.Add("共用图片：$path") }
        $status.Text = "$($script:plan.Documents.Count) 个 Markdown、$($script:plan.Images.Count) 张图片，其中 $($script:plan.Keep.Count) 张仍被其他文档引用。"
        $deleteButton.Enabled = $true
        $moveButton.Enabled = [IO.Directory]::Exists($targetMdBox.Text) -and -not [string]::IsNullOrWhiteSpace($targetImgBox.Text)
    } catch {
        $status.Text = "扫描失败：$($_.Exception.Message)"
    }
}

$mdButton.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]@{ Filter = 'Markdown 文件 (*.md)|*.md'; Title = '选择 Markdown 文件'; Multiselect = $true }
    if ($dialog.ShowDialog() -eq 'OK') {
        $script:markdownPaths = @($dialog.FileNames)
        $mdBox.Text = if ($script:markdownPaths.Count -eq 1) { $script:markdownPaths[0] } else { "已选择 $($script:markdownPaths.Count) 个 Markdown 文件" }
        $firstDirectory = [IO.Path]::GetDirectoryName($script:markdownPaths[0])
        $dirBox.Text = Join-Path $firstDirectory 'assets'
        $scanBox.Text = $firstDirectory
        Refresh-Plan
    }
})

$dirButton.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]@{ Description = '选择 Markdown 图片存储目录'; ShowNewFolderButton = $false }
    if ([IO.Directory]::Exists($dirBox.Text)) { $dialog.SelectedPath = $dirBox.Text }
    if ($dialog.ShowDialog() -eq 'OK') { $dirBox.Text = $dialog.SelectedPath; Refresh-Plan }
})

$scanButton.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]@{ Description = '选择检查共用图片的 Markdown 扫描根目录'; ShowNewFolderButton = $false }
    if ([IO.Directory]::Exists($scanBox.Text)) { $dialog.SelectedPath = $scanBox.Text }
    if ($dialog.ShowDialog() -eq 'OK') { $scanBox.Text = $dialog.SelectedPath; Refresh-Plan }
})

$targetMdButton.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]@{ Description = '选择 Markdown 目标目录'; ShowNewFolderButton = $true }
    if ([IO.Directory]::Exists($targetMdBox.Text)) { $dialog.SelectedPath = $targetMdBox.Text }
    if ($dialog.ShowDialog() -eq 'OK') {
        $targetMdBox.Text = $dialog.SelectedPath
        $targetImgBox.Text = Join-Path $dialog.SelectedPath 'assets'
        Refresh-Plan
    }
})

$targetImgButton.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]@{ Description = '选择图片目标目录'; ShowNewFolderButton = $true }
    if ([IO.Directory]::Exists($targetImgBox.Text)) { $dialog.SelectedPath = $targetImgBox.Text }
    elseif ([IO.Directory]::Exists($targetMdBox.Text)) { $dialog.SelectedPath = $targetMdBox.Text }
    if ($dialog.ShowDialog() -eq 'OK') { $targetImgBox.Text = $dialog.SelectedPath; Refresh-Plan }
})

$deleteButton.Add_Click({
    Refresh-Plan
    if (-not $deleteButton.Enabled) { return }
    $message = "确定移到回收站吗？`n`nMarkdown：$($script:plan.Documents.Count) 个`n图片：$($script:plan.Delete.Count) 张`n扫描范围：$($scanBox.Text)`n`n共用图片不会删除。"
    if ([Windows.Forms.MessageBox]::Show($message, '确认删除', 'YesNo', 'Warning') -ne 'Yes') { return }
    try {
        foreach ($path in $script:plan.Documents) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
        foreach ($path in $script:plan.Delete) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
        [Windows.Forms.MessageBox]::Show('已移到回收站。', '完成', 'OK', 'Information')
        $script:markdownPaths = @(); $mdBox.Clear(); $list.Items.Clear(); $deleteButton.Enabled = $false; $status.Text = '请选择 Markdown 文件。'
    } catch {
        [Windows.Forms.MessageBox]::Show("删除失败：$($_.Exception.Message)", '错误', 'OK', 'Error')
    }
})

$moveButton.Add_Click({
    Refresh-Plan
    if (-not $moveButton.Enabled) { return }
    $message = "确定移动吗？`n`nMarkdown：$($script:plan.Documents.Count) 个`n图片：$($script:plan.Images.Count) 张`n目标 Markdown：$($targetMdBox.Text)`n目标图片：$($targetImgBox.Text)`n`n共用图片会复制，源文件会保留。"
    if ([Windows.Forms.MessageBox]::Show($message, '确认移动', 'YesNo', 'Question') -ne 'Yes') { return }
    try {
        $result = Invoke-MoveBundle $script:plan $dirBox.Text $targetMdBox.Text $targetImgBox.Text
        [Windows.Forms.MessageBox]::Show("移动完成：$($result.Documents) 个 Markdown、$($result.Images) 张图片。`n其中 $($result.SharedCopies) 张共用图片保留了源文件。", '完成', 'OK', 'Information')
        $script:markdownPaths = @(); $mdBox.Clear(); $list.Items.Clear(); $deleteButton.Enabled = $false; $moveButton.Enabled = $false; $status.Text = '请选择 Markdown 文件。'
    } catch {
        [Windows.Forms.MessageBox]::Show("移动失败：$($_.Exception.Message)", '错误', 'OK', 'Error')
    }
})

[void]$form.ShowDialog()
