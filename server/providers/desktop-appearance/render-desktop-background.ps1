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
    [string]${Site} = 'unknown',
    [string]${Role} = 'unknown',
    [int]${Width}  = 1920,
    [int]${Height} = 1080
)

${ErrorActionPreference} = 'Stop'

# Bumping this invalidates every deployed image, so a design change reaches units
# that already have one. It is folded into the sidecar, which verify compares.
${RendererVersion} = 1

# Layout. The text block sits in the lower-left: desktop icons occupy the top-left
# (the single Desktop\MAST folder the desktop-shortcuts provider leaves there), and
# a NoMachine session can be sized smaller than the render, so nothing important
# goes near the right or bottom edge.
${Margin}          = 140
${BlockTopFraction} = 0.52
${AccentBarWidth}  = 8
${AccentBarGap}    = 44
${HostFontSize}    = 128
${SubFontSize}     = 40
${FootFontSize}    = 22
${LineGap}         = 28

${BackgroundColor} = '#0B0E14'
${ForegroundColor} = '#E6EDF3'
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
${footFont} = $null
try {
    ${bitmap}   = New-Object System.Drawing.Bitmap(${Width}, ${Height})
    ${graphics} = [System.Drawing.Graphics]::FromImage(${bitmap})
    ${graphics}.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    ${graphics}.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    ${graphics}.Clear((ConvertTo-DrawingColor -Hex ${BackgroundColor}))

    ${hostFont} = New-Object System.Drawing.Font(${FontFamily}, ${HostFontSize}, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    ${subFont}  = New-Object System.Drawing.Font(${FontFamily}, ${SubFontSize},  [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    ${footFont} = New-Object System.Drawing.Font(${FontFamily}, ${FootFontSize}, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)

    ${textLeft} = ${Margin} + ${AccentBarWidth} + ${AccentBarGap}
    ${blockTop} = [int](${Height} * ${BlockTopFraction})

    ${hostText} = ${ComputerName}.ToUpperInvariant()
    ${subText}  = ('site {0}   role {1}' -f ${Site}, ${Role})
    ${footText} = ('MAST unit   provisioned {0}' -f (Get-Date -Format 'yyyy-MM-dd'))

    ${hostHeight} = ${graphics}.MeasureString(${hostText}, ${hostFont}).Height
    ${subHeight}  = ${graphics}.MeasureString(${subText}, ${subFont}).Height
    ${footHeight} = ${graphics}.MeasureString(${footText}, ${footFont}).Height
    ${blockHeight} = ${hostHeight} + ${LineGap} + ${subHeight} + ${LineGap} + ${footHeight}

    ${accentBrush} = New-Object System.Drawing.SolidBrush((ConvertTo-DrawingColor -Hex ${AccentColor}))
    ${graphics}.FillRectangle(${accentBrush}, ${Margin}, ${blockTop}, ${AccentBarWidth}, ${blockHeight})
    ${accentBrush}.Dispose()

    ${fgBrush} = New-Object System.Drawing.SolidBrush((ConvertTo-DrawingColor -Hex ${ForegroundColor}))
    ${mutedBrush} = New-Object System.Drawing.SolidBrush((ConvertTo-DrawingColor -Hex ${MutedColor}))
    ${y} = [single]${blockTop}
    ${graphics}.DrawString(${hostText}, ${hostFont}, ${fgBrush}, [single]${textLeft}, ${y})
    ${y} = ${y} + ${hostHeight} + ${LineGap}
    ${graphics}.DrawString(${subText}, ${subFont}, ${fgBrush}, [single]${textLeft}, ${y})
    ${y} = ${y} + ${subHeight} + ${LineGap}
    ${graphics}.DrawString(${footText}, ${footFont}, ${mutedBrush}, [single]${textLeft}, ${y})
    ${fgBrush}.Dispose()
    ${mutedBrush}.Dispose()

    New-Item -ItemType Directory -Path (Split-Path -Parent ${OutputPath}) -Force | Out-Null
    ${bitmap}.Save(${OutputPath}, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    if (${footFont}) { ${footFont}.Dispose() }
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
        site          = ${Site}
        role          = ${Role}
    }
    dynamic_fields   = @()
    rendered_at      = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
}
Set-Content -LiteralPath ${SidecarPath} -Encoding ASCII -Value (${sidecar} | ConvertTo-Json -Depth 5)

Write-Host ("Rendered {0}x{1} background for {2} -> {3}" -f ${Width}, ${Height}, ${ComputerName}, ${OutputPath})
exit 0
