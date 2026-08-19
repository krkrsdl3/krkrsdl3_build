@echo off

cd android

echo [1/1] Building Release APK...
call gradlew.bat assembleRelease
echo[
