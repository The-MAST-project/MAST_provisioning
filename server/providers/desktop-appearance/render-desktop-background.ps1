# Render the unit's desktop background, and record what went into it.
#
# The background carries STATIC per-machine identity -- above all the hostname --
# so a remote session can tell at a glance which unit it is looking at
# (MAST_provisioning#54). Everything it shows is fixed for the life of the
# machine's name and site, which is why it is rendered once, machine-wide, by
# provisioning rather than per logon.
#
# It also writes a sidecar JSON next to the image. That is what makes staleness
# detectable: verify-desktop-appearance.ps1 compares the recorded static fields
# against the live machine, so a renamed unit fails rather than keeping a
# background that names the wrong host. A bumped ${RendererVersion} has the same
# effect, which is how a changed design reaches units that already have an image.
#
# THE GROWTH SEAM. Dynamic content (BGInfo-style live IP, uptime, free disk) is
# wanted eventually. When it arrives it lands here and in the sidecar's
# dynamic_fields list, which verify skips -- and the image moves from one
# machine-wide copy to a per-user one regenerated at logon, which is a change to
# apply-desktop-appearance.ps1 only, since that script already owns which path
# the wallpaper points at. Nothing else in the provider has an opinion.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]${OutputPath},
    [Parameter(Mandatory)][string]${SidecarPath},
    [Parameter(Mandatory)][string]${ComputerName},
    # Presentation-ready strings from Get-MastAppearanceFields; this script decides
    # nothing about where they came from. An empty one drops its line.
    [Parameter(Mandatory)][AllowEmptyString()][string]${SiteCode},
    [Parameter(Mandatory)][AllowEmptyString()][string]${SiteName},
    [AllowEmptyString()][string]${Coordinates} = '',
    [int]${Width}  = 1920,
    [int]${Height} = 1080
)

${ErrorActionPreference} = 'Stop'

# Bumping this invalidates every deployed image, so a design change reaches units
# that already have one. It is folded into the sidecar, which verify compares.
${RendererVersion} = 4

# Layout. The text block sits in the lower-left: desktop icons occupy the top-left
# (the single Desktop\MAST folder the desktop-shortcuts provider leaves there), and
# a NoMachine session can be sized smaller than the render, so nothing important
# goes near the right or bottom edge.
# 300, not the 140 this started at: WallpaperStyle 10 (Fill) crops to cover, and a
# 4:3 desktop (1440x1080) discards 240 px from each side -- which at 140 threw away
# the accent bar and the first glyphs of the hostname, the one thing the background
# exists to show. 300 leaves 60 px of slack inside that safe area. Fill is kept over
# style 6 (Fit) because letterboxing looks worse than a wider margin.
${Margin}          = 300
${BlockTopFraction} = 0.48
${AccentBarWidth}  = 8
${AccentBarGap}    = 44
${HostFontSize}    = 128
${SubFontSize}     = 40
${CoordFontSize}   = 28
${FootFontSize}    = 22
${LineGap}         = 28

${BackgroundColor} = '#0B0E14'
# Identity text (hostname and site name). Held well below the top of the palette
# ramp: against #0B0E14 a near-white reads as glare at 128 px on the enclosure
# monitor, not as a label. Still clearly above ${MutedColor}, which the coordinate
# and footer lines use -- the two tiers have to stay distinguishable.
${ForegroundColor} = '#B1BAC4'
${MutedColor}      = '#7D8894'
${AccentColor}     = '#4C7DF0'
${FontFamily}      = 'Segoe UI'

Add-Type -AssemblyName System.Drawing

function ConvertTo-DrawingColor {
    param([Parameter(Mandatory)][string]${Hex})
    return [System.Drawing.ColorTranslator]::FromHtml(${Hex})
}

${bitmap}   = $null
${graphics} = $null
${hostFont} = $null
${subFont}  = $null
${coordFont} = $null
${footFont} = $null
try {
    ${bitmap}   = New-Object System.Drawing.Bitmap(${Width}, ${Height})
    ${graphics} = [System.Drawing.Graphics]::FromImage(${bitmap})
    # Glyphs are filled as outlines (see the drawing loop), so TextRenderingHint only
    # governs MeasureString here. It is still not ClearType: subpixel hinting has no
    # meaning on an offscreen bitmap, and measuring under a hint the render does not
    # use would size the block against the wrong metrics.
    ${graphics}.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    ${graphics}.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    ${graphics}.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    ${graphics}.Clear((ConvertTo-DrawingColor -Hex ${BackgroundColor}))

    ${hostFont} = New-Object System.Drawing.Font(${FontFamily}, ${HostFontSize}, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    ${subFont}  = New-Object System.Drawing.Font(${FontFamily}, ${SubFontSize},  [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
${coordFont} = New-Object System.Drawing.Font(${FontFamily}, ${CoordFontSize}, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    ${footFont} = New-Object System.Drawing.Font(${FontFamily}, ${FootFontSize}, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)

    ${textLeft} = ${Margin} + ${AccentBarWidth} + ${AccentBarGap}
    ${blockTop} = [int](${Height} * ${BlockTopFraction})

    # Role is not on the image: the footer already says 'MAST unit', so a 'role unit'
    # line said it twice.
    ${footText} = ('MAST unit   provisioned {0}' -f (Get-Date -Format 'yyyy-MM-dd'))

    # One entry per drawn line, so a line whose value is empty simply is not there
    # and the block closes up around it.
    ${lines} = @()
    ${lines} += @{ Text = ${ComputerName}.ToUpperInvariant(); Font = ${hostFont};  Brush = 'fg' }
    if (${SiteName})    { ${lines} += @{ Text = ${SiteName};    Font = ${subFont};   Brush = 'fg' } }
    if (${Coordinates}) { ${lines} += @{ Text = ${Coordinates}; Font = ${coordFont}; Brush = 'muted' } }
    ${lines} += @{ Text = ${footText}; Font = ${footFont}; Brush = 'muted' }

    ${blockHeight} = 0
    foreach (${line} in ${lines}) {
        ${line}.Height = ${graphics}.MeasureString(${line}.Text, ${line}.Font).Height
        ${blockHeight} = ${blockHeight} + ${line}.Height
    }
    ${blockHeight} = ${blockHeight} + (${LineGap} * (${lines}.Count - 1))

    ${accentBrush} = New-Object System.Drawing.SolidBrush((ConvertTo-DrawingColor -Hex ${AccentColor}))
    ${graphics}.FillRectangle(${accentBrush}, ${Margin}, ${blockTop}, ${AccentBarWidth}, ${blockHeight})
    ${accentBrush}.Dispose()

    ${brushes} = @{
        fg    = New-Object System.Drawing.SolidBrush((ConvertTo-DrawingColor -Hex ${ForegroundColor}))
        muted = New-Object System.Drawing.SolidBrush((ConvertTo-DrawingColor -Hex ${MutedColor}))
    }
    # Every line is converted to an outline and filled, rather than drawn with
    # DrawString. GDI+ ClearType has no subpixel layout to filter against when the
    # target is an offscreen Bitmap and degrades to near-binary edges; the steps are
    # invisible on the 22-40 px lines and unmissable on a 128 px hostname, which is
    # what made the identity text look ragged at any resolution. Filling the glyph
    # outline antialiases against real coverage, so it is smooth at any size.
    ${y} = [single]${blockTop}
    foreach (${line} in ${lines}) {
        ${path} = New-Object System.Drawing.Drawing2D.GraphicsPath
        try {
            ${path}.AddString(
                ${line}.Text,
                ${line}.Font.FontFamily,
                [int]${line}.Font.Style,
                ${line}.Font.Size,
                (New-Object System.Drawing.PointF([single]${textLeft}, ${y})),
                [System.Drawing.StringFormat]::GenericDefault)
            ${graphics}.FillPath(${brushes}[${line}.Brush], ${path})
        }
        finally { ${path}.Dispose() }
        ${y} = ${y} + ${line}.Height + ${LineGap}
    }
    ${brushes}.Values | ForEach-Object { $_.Dispose() }

    New-Item -ItemType Directory -Path (Split-Path -Parent ${OutputPath}) -Force | Out-Null
    ${bitmap}.Save(${OutputPath}, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    if (${footFont}) { ${footFont}.Dispose() }
    if (${coordFont}) { ${coordFont}.Dispose() }
    if (${subFont})  { ${subFont}.Dispose() }
    if (${hostFont}) { ${hostFont}.Dispose() }
    if (${graphics}) { ${graphics}.Dispose() }
    if (${bitmap})   { ${bitmap}.Dispose() }
}

# static_fields is what verify compares; dynamic_fields is empty today and is the
# list verify will have to skip once anything on the image is live.
${sidecar} = [ordered]@{
    renderer         = 'render-desktop-background.ps1'
    renderer_version = ${RendererVersion}
    image            = ${OutputPath}
    width            = ${Width}
    height           = ${Height}
    static_fields    = [ordered]@{
        computer_name = ${ComputerName}
        site          = ${SiteCode}
        site_name     = ${SiteName}
        coordinates   = ${Coordinates}
    }
    dynamic_fields   = @()
    rendered_at      = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
}
Set-Content -LiteralPath ${SidecarPath} -Encoding ASCII -Value (${sidecar} | ConvertTo-Json -Depth 5)

Write-Host ("Rendered {0}x{1} background for {2} -> {3}" -f ${Width}, ${Height}, ${ComputerName}, ${OutputPath})
exit 0
