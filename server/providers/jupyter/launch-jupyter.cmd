@echo off
REM MAST Jupyter Notebook launcher.
REM All Jupyter state is kept under C:\MAST\jupyter so it does not litter the user
REM profile (%APPDATA%\jupyter, %USERPROFILE%\.jupyter). Deployed by the jupyter
REM provider; the desktop shortcut points here.
set "JUPYTER_DATA_DIR=C:\MAST\jupyter\data"
set "JUPYTER_CONFIG_DIR=C:\MAST\jupyter\config"
set "JUPYTER_RUNTIME_DIR=C:\MAST\jupyter\runtime"
if not exist "C:\MAST\jupyter\notebooks" mkdir "C:\MAST\jupyter\notebooks"
cd /d "C:\MAST\jupyter\notebooks"
"C:\MAST\jupyter\.venv\Scripts\jupyter-notebook.exe" %*
