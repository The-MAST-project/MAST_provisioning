# Canonical MAST nssm service inventory, and the start mode provisioning must
# leave each service in. Single source of truth, shared by the two providers
# that act on it: mast-services-standdown (order 20) makes it so, and
# mast-services-finalize (order 9500) asserts it at the end of the run.
#
# Why the two start modes differ: a running mast-unit commands hardware on
# process start (MAST_unit#132 -- covers open, mount homes) with no interlock
# anywhere in the stack, so provisioning leaves it Disabled and an operator
# enables it deliberately. The three prerequisite processes move nothing by
# coming up. They are on their way out with the supervisor topology (#82) and
# will join mast-unit at Disabled then; see #159.
#
# mast-unit is listed FIRST so it is stopped before mast-pwi4, which it depends
# on: stopping a dependency with -Force would otherwise take the dependent down.
function Get-MastServiceExpectations {
    [ordered]@{
        'mast-unit'      = 'Disabled'
        'mast-pwi4'      = 'Manual'
        'mast-pwshutter' = 'Manual'
        'mast-phd2'      = 'Manual'
    }
}

# The services provisioning must never leave startable -- the stand-down set.
function Get-MastStandDownServiceNames {
    ${expectations} = Get-MastServiceExpectations
    @(${expectations}.Keys | Where-Object { ${expectations}[$_] -eq 'Disabled' })
}
