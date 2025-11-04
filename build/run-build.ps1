# From <TOP>\build (or anywhere)
.\build-mast.ps1 `
  -Top "C:\Users\User\source\repos\MAST-provisioning" `
  -Count 20 `
  -Modules @('cygwin','mongodb','nomachine','ascom') `
  -Overrides @{ mongodb = @{ NoCompass = $true } } `
  -PreAllocateNoMachineLicense
