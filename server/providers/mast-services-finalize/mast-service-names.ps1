# Canonical list of MAST NSSM service names (mast-* naming). Single source of
# truth shared by provide-mast-services-finalize.ps1 and its verify script.
# mast-unit is listed FIRST so it is stopped before mast-pwi4 (which it depends
# on): stopping a dependency with -Force would otherwise take the dependent down.
function Get-MastServiceNames {
    @('mast-unit', 'mast-pwi4', 'mast-pwshutter', 'mast-phd2')
}
