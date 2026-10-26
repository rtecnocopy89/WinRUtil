function Get-WinUtilAppCategoryName {
    <#
    .SYNOPSIS
        Returns the Italian name shown for a category of applications.json

    .PARAMETER Category
        The category as written in applications.json. A category without a translation is shown as it is.

    .EXAMPLE
        Get-WinUtilAppCategoryName -Category "Multimedia Tools"
    #>

    param([string]$Category)

    $names = @{
        "Browsers"         = "Browser"
        "Communications"   = "Comunicazione"
        "Development"      = "Sviluppo"
        "Document"         = "Documenti"
        "Games"            = "Giochi"
        "Microsoft Tools"  = "Strumenti Microsoft"
        "Multimedia Tools" = "Multimedia"
        "Pro Tools"        = "Strumenti professionali"
        "Selfhosted Tools" = "Self-hosted"
        "Utilities"        = "Utilit$([char]0x00E0)"
    }

    if ($names.ContainsKey($Category)) {
        return $names[$Category]
    }
    return $Category
}
