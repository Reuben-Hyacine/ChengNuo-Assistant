@echo off
title 程诺 App 启动器（仅前端）
setlocal EnableExtensions

rem ================= 可调参数（与根目录 start-all.bat 保持一致）=================
set "FRONTEND_DIR=%~dp0"
set "HAP_DIR=%FRONTEND_DIR%entry\build\default\outputs\default"
set "HDC="                    rem 留空=自动探测（DevEco 安装位置/SDK 环境变量/devecocli/PATH）；也可手动填 hdc 完整路径
set "SERIAL=127.0.0.1:5555"   rem 首选串号；不在线时自动采用实际在线的设备
set "EMULATOR=Pura 90 Pro"    rem 首选模拟器名；本机不存在时自动改用第一个手机(phone)模拟器
set "BUNDLE=com.chengnuo.app"
set "ABILITY=EntryAbility"
rem 用法: 双击 start.bat       仅启动前端（模拟器 + 程诺 App）
rem       start.bat build     启动前强制重新构建 App
rem       start.bat auto      内部使用: 启动完成即退出
rem ==============================================================

echo ==============================================================
echo    程诺 App 启动器（仅前端）
echo    只负责: 手机模拟器  +  程诺 App
echo    不负责: 服务器 :3000 / 客户端 :4000（完整启动请用
echo            根目录 start-all.bat 或 client\start.bat）
echo ==============================================================
echo.

rem ---- 环境自检 ----
if not exist "%FRONTEND_DIR%entry\src\main\ets" set "FAILMSG=前端工程目录结构不完整: %FRONTEND_DIR%" & goto fail_end
call :find_hdc
if errorlevel 1 set "FAILMSG=脚本顶部手动指定的 HDC 不存在: %HDC%  请修正该路径" & goto fail_end
if not defined HDC set "FAILMSG=未找到 hdc：已搜索 DEVECO_SDK_HOME、各盘常见 DevEco Studio 安装位置、devecocli 自带 hdc 及 PATH。可在脚本顶部 set HDC=完整路径" & goto fail_end
where devecocli >nul 2>&1
if errorlevel 1 if not exist "%USERPROFILE%\.cache\deveco\bin\devecocli.cmd" set "FAILMSG=devecocli 未安装（PATH 与默认目录均未找到）" & goto fail_end
if errorlevel 1 set "PATH=%PATH%;%USERPROFILE%\.cache\deveco\bin"
where curl >nul 2>&1
if errorlevel 1 set "FAILMSG=curl 不可用（Windows 10 以上自带）" & goto fail_end
where powershell >nul 2>&1
if errorlevel 1 set "FAILMSG=powershell 不可用（模拟器自动识别需要它）" & goto fail_end

rem ================== [1/4] 后端状态检测（只提示，不启动）==================
echo [1/4] 检查客户端后端 (:4000)...
curl -s -m 2 http://127.0.0.1:4000/api/health >nul 2>&1
if not %errorlevel%==0 goto backend_down
echo       后端已经就绪
goto backend_checked
:backend_down
echo       [警告] 后端(:4000) 未启动 — App 将提示连接失败
echo              一并启动后端+前端: client\start.bat
echo              完整启动: 根目录 start-all.bat
:backend_checked

rem ================== [2/4] 连接设备 / 启动手机模拟器 ==========================
echo [2/4] 检查在线设备与手机模拟器...
set "COLD="
call :pick_target
if defined FOUND set "SERIAL=%FOUND%" & goto emu_ready
set "COLD=1"
call :resolve_emulator
if not defined EMULATOR set "FAILMSG=未找到手机模拟器：devecocli emulator list 中没有 phone 类型实例。请先在 DevEco Studio Device Manager 创建手机模拟器" & goto fail_end
echo       无在线设备，冷启动模拟器「%EMULATOR%」（首次约 1-4 分钟，请耐心等待）...
call devecocli emulator start "%EMULATOR%"
if errorlevel 1 set "FAILMSG=模拟器 %EMULATOR% 启动失败，请运行 devecocli emulator list 核实" & goto fail_end
rem 预防性重启 hdc 服务：模拟器 stop→start 后长期存活的 hdc server 会缓存旧连接状态
call "%HDC%" kill >nul 2>&1
set /a EWAIT=0
:wait_emu
call :pick_target
if defined FOUND set "SERIAL=%FOUND%" & goto emu_settle
set /a EWAIT+=5
if %EWAIT% geq 300 set "FAILMSG=等待模拟器超时（5 分钟）" & goto fail_end
ping -n 6 127.0.0.1 >nul
echo       ...已等待 %EWAIT% 秒
goto wait_emu
:emu_settle
echo       设备已出现（%SERIAL%），等待系统稳定（10 秒）...
ping -n 11 127.0.0.1 >nul
:emu_ready
if not defined COLD goto emu_unlocked
echo       正在亮屏并解锁...
call "%HDC%" -t %SERIAL% shell "power-shell wakeup" >nul 2>&1
ping -n 4 127.0.0.1 >nul
call "%HDC%" -t %SERIAL% shell "uinput -T -m 360 1200 360 300" >nul 2>&1
ping -n 3 127.0.0.1 >nul
:emu_unlocked
call "%HDC%" -t %SERIAL% shell "power-shell timeout -o 600000" >nul 2>&1
echo       设备已经就绪（%SERIAL%）

rem ================== [3/4] 安装 App ============================
echo [3/4] 准备程诺 App...
call :find_hap
if defined HAP goto hap_ready
echo       未找到安装包，先构建工程（首次约 30 秒）...
call :do_build
if errorlevel 1 goto build_fail
call :find_hap
if not defined HAP goto build_fail
goto hap_final
:hap_ready
if /i not "%~1"=="build" goto hap_final
echo       检测到 build 参数，重新构建 App...
call :do_build
if errorlevel 1 goto build_fail
call :find_hap
if not defined HAP goto build_fail
:hap_final
echo       安装包: %HAP%
set "INS_CLEAN="
set /a ITRY=0
:ins_loop
echo       安装到设备（%SERIAL%）...
call :ins_once
if "%INS_RESULT%"=="ok" goto install_ok
if "%INS_RESULT%"=="sign" goto ins_sign
if "%INS_RESULT%"=="channel" goto ins_channel
if "%INS_RESULT%"=="hang" goto ins_hang
rem 其他错误：最多重试 3 次
if %ITRY% lss 3 echo       安装失败，重试 %ITRY%/3...
if %ITRY% lss 3 goto ins_loop
set "FAILMSG=App 安装失败: %INS_REASON%" & goto fail_end
:ins_sign
echo       与已装版本签名不一致，卸载旧版后重装...
call "%HDC%" -t %SERIAL% shell bm uninstall -n %BUNDLE% >nul 2>&1
set "INS_CLEAN=1"
if %ITRY% geq 3 set "FAILMSG=App 安装失败: 签名不一致且卸载重装未成功" & goto fail_end
goto ins_loop
:ins_channel
if %ITRY% geq 3 set "FAILMSG=App 安装失败: hdc 文件通道无法建立（%INS_REASON%）" & goto fail_end
echo       hdc 文件通道建立中，5 秒后重试...
ping -n 6 127.0.0.1 >nul
goto ins_loop
:ins_hang
echo       安装疑似挂死（120 秒无响应），重启 hdc 服务后重试...
call "%HDC%" kill >nul 2>&1
call :wait_shell
if errorlevel 1 set "FAILMSG=重启 hdc 服务后设备 %SERIAL% 未恢复" & goto fail_end
if %ITRY% geq 3 set "FAILMSG=App 安装持续挂死: hdc 文件通道异常，请重启模拟器后再运行本脚本" & goto fail_end
goto ins_loop
:install_ok
echo       安装成功

rem ================== [4/4] 启动 App ============================
echo [4/4] 启动程诺 App...
set /a TRIES=0
:launch
call "%HDC%" -t %SERIAL% shell aa start -a %ABILITY% -b %BUNDLE% >nul 2>&1
if %errorlevel%==0 goto launched
set /a TRIES+=1
if %TRIES% geq 5 set "FAILMSG=App 启动失败（系统未就绪?），请稍后手动启动" & goto fail_end
ping -n 7 127.0.0.1 >nul
echo       系统启动中，重试 %TRIES%/5...
goto launch
:launched
rem 冷启动时首次启动可能被开机动画拦截，3 秒后再启动一次，确保前台稳定
if not defined COLD goto launch_done
ping -n 4 127.0.0.1 >nul
call "%HDC%" -t %SERIAL% shell aa start -a %ABILITY% -b %BUNDLE% >nul 2>&1
:launch_done
echo       启动成功
echo.
echo ==============================================================
echo   前端启动完成
echo     - 设备 %SERIAL%（模拟器 %EMULATOR%）
echo     - 程诺 App 已打开
echo   提示: 改完代码后  start.bat build  可重新构建并安装
echo ==============================================================
if /i "%~1"=="auto" exit /b 0
if /i "%~2"=="auto" exit /b 0
pause
exit /b 0

:find_hdc
rem 定位 hdc：手动指定(须存在) → SDK 环境变量 → 各盘常见 DevEco Studio 安装位置 → devecocli 自带 hdc → PATH 中的 hdc.exe
rem 注意: HDC 可能是 .cmd 包装器，所有调用处必须用 call 前缀，否则批处理控制权会被转移
if defined HDC (
  if exist "%HDC%" exit /b 0
  exit /b 1
)
if defined DEVECO_SDK_HOME if exist "%DEVECO_SDK_HOME%\default\openharmony\toolchains\hdc.exe" set "HDC=%DEVECO_SDK_HOME%\default\openharmony\toolchains\hdc.exe"
if defined HDC exit /b 0
if defined DEVECO_SDK_HOME if exist "%DEVECO_SDK_HOME%\openharmony\toolchains\hdc.exe" set "HDC=%DEVECO_SDK_HOME%\openharmony\toolchains\hdc.exe"
if defined HDC exit /b 0
if defined HOS_SDK_HOME if exist "%HOS_SDK_HOME%\toolchains\hdc.exe" set "HDC=%HOS_SDK_HOME%\toolchains\hdc.exe"
if defined HDC exit /b 0
for %%D in (C D E F G H) do (
  for %%P in ("%%D:\DevEco Studio" "%%D:\Huawei\DevEco Studio" "%%D:\Program Files\Huawei\DevEco Studio") do (
    if not defined HDC if exist "%%~P\sdk\default\openharmony\toolchains\hdc.exe" set "HDC=%%~P\sdk\default\openharmony\toolchains\hdc.exe"
  )
)
if defined HDC exit /b 0
if exist "%USERPROFILE%\.cache\deveco\bin\hdc.cmd" set "HDC=%USERPROFILE%\.cache\deveco\bin\hdc.cmd"
if defined HDC exit /b 0
for /f "delims=" %%I in ('where devecocli 2^>nul') do if not defined HDC if exist "%%~dpIhdc.cmd" set "HDC=%%~dpIhdc.cmd"
if defined HDC exit /b 0
for /f "delims=" %%I in ('where hdc.exe 2^>nul') do if not defined HDC set "HDC=%%I"
if defined HDC exit /b 0
for /d %%V in ("%LOCALAPPDATA%\Huawei\Sdk\*") do if not defined HDC if exist "%%~V\openharmony\toolchains\hdc.exe" set "HDC=%%~V\openharmony\toolchains\hdc.exe"
for /d %%V in ("%LOCALAPPDATA%\OpenHarmony\Sdk\*") do if not defined HDC if exist "%%~V\openharmony\toolchains\hdc.exe" set "HDC=%%~V\openharmony\toolchains\hdc.exe"
exit /b 0

:pick_target
rem 输出: FOUND=选中的设备串号（空=当前无在线设备）
rem 优先级: 配置的 SERIAL → 任意 127.0.0.1:*（模拟器）→ 唯一在线的其他设备（真机）
rem 说明: hdc 输出行可能带多余的 CR（如 [Empty] 实为 "[Empty]\r"），因此用 PowerShell 读取并 Trim，再过滤 [Empty]
set "FOUND="
set "CN_SERIAL=%SERIAL%"
call "%HDC%" list targets > "%TEMP%\cn-targets.txt" 2>nul
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "$lines = @(Get-Content $env:TEMP\cn-targets.txt -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('[Empty]') }); if ($lines.Count -eq 0) { exit 0 }; $hit = @($lines | Where-Object { $_ -eq $env:CN_SERIAL }); if ($hit.Count -gt 0) { Write-Output $hit[0]; exit 0 }; $emu = @($lines | Where-Object { $_.StartsWith('127.0.0.1:') }); if ($emu.Count -gt 0) { Write-Output $emu[0]; exit 0 }; Write-Output $lines[0]"`) do if not defined FOUND set "FOUND=%%T"
exit /b 0

:resolve_emulator
rem 解析手机模拟器名：首选 EMULATOR 存在则沿用，否则自动取第一个 phone 类型
set "PREFERRED_EMU=%EMULATOR%"
set "EMULATOR="
for /f "usebackq delims=" %%N in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$raw = devecocli emulator list --format json | Out-String; $m = [regex]::Match($raw, '(?s)\[\s*\{.*\}\s*\]'); if (-not $m.Success) { exit 2 }; $list = ConvertFrom-Json $m.Value; $phone = @($list | Where-Object deviceType -eq 'phone'); if ($phone.Count -eq 0) { exit 2 }; $p = @($phone | Where-Object name -eq $env:PREFERRED_EMU); if ($p.Count -gt 0) { $p[0].name } else { $phone[0].name }"`) do if not defined EMULATOR set "EMULATOR=%%N"
exit /b 0

:find_hap
set "HAP="
for /f "delims=" %%F in ('dir /b /o-d "%HAP_DIR%\*.hap" 2^>nul') do if not defined HAP set "HAP=%HAP_DIR%\%%F"
exit /b 0

:ins_once
rem 执行一次安装，输出 INS_RESULT=ok/sign/channel/hang/fail 与 INS_REASON
rem 要点1: hdc 失败时退出码也可能是 0（实测 E001005/E000004/签名错误均返回0），必须检查输出文本
rem 要点2: 冷启动后文件通道未就绪时 install 会无限挂死，用 PowerShell 包一层 120 秒超时并强杀进程树
set "INS_RESULT=fail"
set "INS_REASON="
set "INS_MODE=-r"
if defined INS_CLEAN set "INS_MODE="
set "INS_LOG=%TEMP%\cn-install.txt"
del "%INS_LOG%" 2>nul
powershell -NoProfile -Command "$psi = New-Object Diagnostics.ProcessStartInfo; $psi.FileName = 'cmd.exe'; $psi.Arguments = '/c call \"' + $env:HDC + '\" -t ' + $env:SERIAL + ' install ' + $env:INS_MODE + ' \"' + $env:HAP + '\" > \"' + $env:INS_LOG + '\" 2>&1'; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $p = [Diagnostics.Process]::Start($psi); if (-not $p.WaitForExit(120000)) { taskkill /T /F /PID $p.Id | Out-Null; exit 3 }; exit 0"
if errorlevel 3 set "INS_RESULT=hang" & exit /b 0
findstr /c:"successfully" "%INS_LOG%" >nul 2>&1
if not errorlevel 1 set "INS_RESULT=ok" & exit /b 0
findstr /c:"sign info inconsistent" "%INS_LOG%" >nul 2>&1
if not errorlevel 1 set "INS_RESULT=sign" & set "INS_REASON=签名与已装版本不一致" & exit /b 0
findstr /c:"E000004" "%INS_LOG%" >nul 2>&1
if not errorlevel 1 set "INS_RESULT=channel" & set "INS_REASON=文件通道建立中" & exit /b 0
for /f "usebackq delims=" %%L in ("%INS_LOG%") do if not defined INS_REASON set "INS_REASON=%%L"
if not defined INS_REASON set "INS_REASON=未知错误（安装命令无输出）"
exit /b 0

:wait_shell
rem hdc server 重启后等待设备 shell 恢复可用；45 秒超时返回 errorlevel 1
set /a KWAIT=0
:wsh_loop
call "%HDC%" -t %SERIAL% shell "echo ok" >nul 2>&1
if not errorlevel 1 exit /b 0
set /a KWAIT+=3
if %KWAIT% geq 45 exit /b 1
ping -n 4 127.0.0.1 >nul
goto wsh_loop

:do_build
pushd "%FRONTEND_DIR%"
call devecocli build
set "BERR=%errorlevel%"
popd
exit /b %BERR%

:build_fail
set "FAILMSG=App 构建失败，请查看上方构建日志"
goto fail_end

:fail_end
echo.
echo [失败] %FAILMSG%
if /i "%~1"=="auto" exit /b 1
if /i "%~2"=="auto" exit /b 1
pause
exit /b 1
