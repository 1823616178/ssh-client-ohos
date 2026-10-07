@echo off
setlocal
set "DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk"
set "JAVA_HOME=C:\Program Files\Huawei\DevEco Studio\jbr"
set "PATH=%JAVA_HOME%\bin;%PATH%"
cd /d C:\Users\lx182\DevEcoStudioProjects\ssh_client_ohos
echo JAVA_HOME=%JAVA_HOME%
echo DEVECO_SDK_HOME=%DEVECO_SDK_HOME%
"C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" %*
echo HVIGOR_EXIT=%ERRORLEVEL%
