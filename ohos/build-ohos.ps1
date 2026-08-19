<#
.SYNOPSIS
    krkrsdl3 OpenHarmony 构建 (由 script/build-ohos.bat 调用)

.DESCRIPTION
    用法: script\build-ohos.bat <sdk-root> <target> <arch> <buildtype>

    命令:
      full      全量构建 (deps → hap)
      deps      交叉编译依赖
      hap       打包 HAP (hvigorw 自动编译 native + ArkTS)
      clean     清理 out/ohos

.PARAMETER Arch
    目标架构: arm64-v8a (默认) | armeabi-v7a | x86_64
#>

param(
    [Parameter(Position=0)]
    [ValidateSet("full","deps","hap","clean")]
    [string]$Target = "full",

    [Parameter(Position=1)]
    [string]$Arch = "arm64-v8a",

    [Parameter(Position=2)]
    [string]$BuildType = "debug",

    [Parameter(Position=3)]
    [string]$SdkRoot = "C:\D\command-line-tools"
)

$ErrorActionPreference = "Continue"
$Root = [System.IO.Path]::GetFullPath("$PSScriptRoot\..\")
$msys2Root = "C:\D\MSYS2"
$SDK = "$SdkRoot\sdk\default\openharmony\native"
$BuildDir = "$Root\out\ohos\$Arch"
$DepsDst = "$Root\out\ohos\deps\install\$Arch"
$DepsSrc = "$Root\out\ohos\deps\src"
$Prebuild = "$Root\ohos\prebuild"
$CC = "$SDK\llvm\bin\clang.exe"
$AR = "$SDK\llvm\bin\llvm-ar.exe"
$Sysroot = "$SDK\sysroot"
$Toolchain = "$SDK\build\cmake\ohos.toolchain.cmake"
$Triple = if ($Arch -eq "arm64-v8a") { "aarch64-linux-ohos" }
           elseif ($Arch -eq "armeabi-v7a") { "arm-linux-ohos" }
           else { "x86_64-linux-ohos" }
$Hvigorw = "$SdkRoot\bin\hvigorw.bat"
$DevEcoNodeHome = "$SdkRoot\tool\node"

# ================================================================
#  BUILD COMMANDS
# ================================================================

function Invoke-Deps {
    Write-Host "=== Building dependencies ==="
    if (Test-Path "$DepsDst\.stamp") {
        Write-Host "  Already built. (remove $DepsDst\.stamp to force)"
        return
    }
    New-Item -ItemType Directory -Force -Path "$DepsSrc","$DepsDst\lib","$DepsDst\include" | Out-Null

    function _git($name, $url, $branch) {
        $d = "$DepsSrc\$name"
        if (-not (Test-Path $d)) {
            Write-Host "  git clone $url -> $name"
            $null = git clone -q --depth 1 --branch $branch $url $d 2>&1
        }
    }
    function _cmake($name, $extra) {
        Push-Location "$DepsSrc\$name"
        if (Test-Path build) { Remove-Item -Force -Recurse build }
        $a = @("-G","Ninja","-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
               "-DCMAKE_TOOLCHAIN_FILE=$Toolchain","-DOHOS_ARCH=$Arch",
               "-DCMAKE_BUILD_TYPE=Release","-DBUILD_SHARED_LIBS=OFF",
               "-DCMAKE_INSTALL_PREFIX=$DepsDst","-B","build","-S",".")
        if ($extra) { $a += $extra -split ' ' | Where-Object { $_ } }
        $null = & cmake $a 2>&1; if ($LASTEXITCODE) { throw "$name cmake failed" }
        $null = cmake --build build --config Release --parallel 2>&1; if ($LASTEXITCODE) { throw "$name build failed" }
        $null = cmake --install build --prefix $DepsDst 2>&1; if ($LASTEXITCODE) { throw "$name install failed" }
        Pop-Location
    }

    # --- zlib (cmake) ---
    Write-Host "[zlib]"
    _git zlib https://github.com/madler/zlib.git v1.3.1
    _cmake zlib ""

    # --- libpng (disable NEON: palette expand bug on OHOS ARM) ---
    Write-Host "[libpng]"
    _git libpng https://github.com/pnggroup/libpng.git v1.6.43
    _cmake libpng "-DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_ARM_NEON=off"

    # --- libjpeg-turbo ---
    Write-Host "[libjpeg-turbo]"
    _git libjpeg-turbo https://github.com/libjpeg-turbo/libjpeg-turbo.git 3.0.4
    _cmake libjpeg-turbo "-DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=ON"

    # --- libogg ---
    Write-Host "[libogg]"
    _git ogg https://github.com/xiph/ogg.git v1.3.5
    _cmake ogg ""

    # --- opus ---
    Write-Host "[opus]"
    _git opus https://github.com/xiph/opus.git v1.5.2
    _cmake opus ""

    # --- libvorbis ---
    Write-Host "[libvorbis]"
    _git vorbis https://github.com/xiph/vorbis.git v1.3.7
    _cmake vorbis "-DOGG_INCLUDE_DIR=$DepsDst\include -DOGG_LIBRARY=$DepsDst\lib\libogg.a"

    # --- opusfile (no cmake, manual build) ---
    Write-Host "[opusfile]"
    _git opusfile https://github.com/xiph/opusfile.git v0.12
    Push-Location "$DepsSrc\opusfile"
    $null = & $CC --target=$Triple --sysroot=$Sysroot -fPIC -D__MUSL__ -O2 -Iinclude "-I$DepsDst\include" "-I$DepsDst\include\opus" -c src/opusfile.c src/stream.c src/http.c src/internal.c src/info.c src/wincerts.c 2>&1
    & $AR rcs "$DepsDst\lib\libopusfile.a" *.o
    Copy-Item include\opusfile.h "$DepsDst\include\" -Force
    $null = New-Item -ItemType Directory -Force -Path "$DepsDst\include\opus"
    Copy-Item include\opusfile.h "$DepsDst\include\opus\" -Force
    Pop-Location

    # --- freetype ---
    Write-Host "[freetype]"
    _git freetype https://github.com/freetype/freetype.git VER-2-13-2
    _cmake freetype "-DFT_DISABLE_BZIP2=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON -DPNG_ROOT=$DepsDst -DZLIB_ROOT=$DepsDst"

    # --- libwebp ---
    Write-Host "[libwebp]"
    _git libwebp https://github.com/webmproject/libwebp.git v1.4.0
    _cmake libwebp ""

    # --- oniguruma ---
    Write-Host "[oniguruma]"
    _git oniguruma https://github.com/kkos/oniguruma.git v6.9.9
    _cmake oniguruma ""

    # --- glm (header-only) ---
    Write-Host "[glm]"
    _git glm https://github.com/g-truc/glm.git 1.0.1
    Copy-Item -Recurse "$DepsSrc\glm\glm" "$DepsDst\include\glm" -Force

    # --- ffmpeg (from source) ---
    Write-Host "[ffmpeg]"
    $ffBuild = "$DepsSrc\ffmpeg"
    $ffStamp = "$DepsDst\.stamp_ffmpeg"
    if (-not (Test-Path $ffStamp)) {
        if (-not (Test-Path "$ffBuild\configure")) {
            Write-Host "  cloning ffmpeg 7.1..."
            $null = git clone -q --depth 1 --branch n7.1 https://github.com/FFmpeg/FFmpeg.git $ffBuild 2>&1
        }
        $ffOut = "$BuildDir\ffmpeg_install"
        New-Item -ItemType Directory -Force -Path $ffOut | Out-Null

        $llvmBin = ($SDK + "/llvm/bin") -replace '\\','/'
        $ffSrc = $ffBuild -replace '\\','/'
        $ffPfx = $ffOut -replace '\\','/'
        $sr = $Sysroot -replace '\\','/'
        # target-specific clang (auto-sets --target, no extra cflags needed)
        $CC = $llvmBin + "/aarch64-unknown-linux-ohos-clang"
        $CXX = $llvmBin + "/aarch64-unknown-linux-ohos-clang++"
        $LD = $llvmBin + "/ld.lld"
        $STRIP = $llvmBin + "/llvm-strip"
        $RANLIB = $llvmBin + "/llvm-ranlib"
        $AR = $llvmBin + "/llvm-ar"
        $NM = $llvmBin + "/llvm-nm"
        # host native compiler & bash — all from MSYS2
        $HOST_CC = ($msys2Root + "\mingw64\bin\gcc.exe") -replace '\\','/' -replace 'C:','/c'
        $HOST_BIN = ($msys2Root + "\mingw64\bin") -replace '\\','/' -replace 'C:','/c'
        $BASH = $msys2Root + "\usr\bin\bash.exe"

        $shPath = "$BuildDir\build_ffmpeg.sh"
        # Write bash script line by line — avoid PS quoting hell
        $sh = [System.Collections.Generic.List[string]]::new()
        $sh.Add("#!/bin/bash")
        $sh.Add("set -e")
        $sh.Add("export CC='$CC'")
        $sh.Add("export CXX='$CXX'")
        $sh.Add("export LD='$LD'")
        $sh.Add("export STRIP='$STRIP'")
        $sh.Add("export RANLIB='$RANLIB'")
        $sh.Add("export AR='$AR'")
        $sh.Add("export NM='$NM'")
        $sh.Add("export CFLAGS='-DOHOS_NDK -fPIC -D__MUSL__=1 -O3'")
        $sh.Add("export CXXFLAGS='-DOHOS_NDK -fPIC -D__MUSL__=1 -O3'")
        $sh.Add("export LDFLAGS=''")
        $sh.Add("export PATH=""$llvmBin"":""$HOST_BIN"":`$PATH")
        $sh.Add("cd ""$ffSrc""")
        $sh.Add("./configure \")
        $sh.Add("  --disable-neon --disable-asm --disable-x86asm \")
        $sh.Add("  --enable-cross-compile --target-os=linux --arch=aarch64 \")
        $sh.Add("  --cc=${CC} --cxx=${CXX} --ld=${CC} \")
        $sh.Add("  --host-cc=$HOST_CC --host-ld=$HOST_CC --host-os=linux \")
        $sh.Add("  --ar=${AR} --ranlib=${RANLIB} --strip=${STRIP} \")
        $sh.Add("  --sysroot=""$sr"" \")
        $sh.Add("  --prefix=""$ffPfx"" \")
        $sh.Add("  --enable-static --disable-shared \")
        $sh.Add("  --enable-pic --disable-doc --disable-htmlpages \")
        $sh.Add("  --disable-autodetect \")
        $sh.Add("  --disable-encoders --disable-muxers --disable-indevs --disable-outdevs \")
        $sh.Add("  --disable-programs \")
        $sh.Add("  --enable-protocols \")
        $sh.Add("  --enable-avcodec --enable-avformat --enable-avutil \")
        $sh.Add("  --enable-swresample --enable-swscale \")
        $sh.Add("  --enable-decoder=h264,hevc,mpeg4,mpeg2video,mpeg1video,flv,vp8,vp9,mjpeg \")
        $sh.Add("  --enable-decoder=aac,mp3,flac,vorbis,opus \")
        $sh.Add("  --enable-decoder=pcm_s16le,pcm_f32le,pcm_s16be,pcm_u8 \")
        $sh.Add("  --enable-demuxer=matroska,avi,mp4,mov,flv,mpegts,mpegps,ogg,wav,aac,mp3 \")
        $sh.Add("  --enable-parser=h264,hevc,mpeg4video,mpegvideo,aac,mp3,flac,vorbis,opus")
        $sh.Add("make -j4")
        $sh.Add("make install")
        [System.IO.File]::WriteAllText($shPath, ($sh -join "`n"))

        Write-Host "  bash: $BASH"
        Write-Host "  running FFmpeg configure + make (5-15 min)..."
        & $BASH --login $shPath 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ffmpeg build FAILED (see above)"
            return
        }
        Copy-Item -Force "$ffOut\lib\*.a" "$DepsDst\lib\" -ErrorAction SilentlyContinue
        Copy-Item -Recurse -Force "$ffOut\include\*" "$DepsDst\include\" -ErrorAction SilentlyContinue
        "done" | Set-Content $ffStamp
        Write-Host "  ffmpeg 7.1 built"
    } else {
        Write-Host "  ffmpeg 7.1 (cached)"
    }

    # --- plutovg ---
    Write-Host "[plutovg]"
    _git plutovg https://github.com/sammycage/plutovg.git v0.0.6
    _cmake plutovg ""

    # --- post-install ---
    Write-Host "[post-install]"
    Copy-Item "$DepsDst\include\plutovg\plutovg.h" "$DepsDst\include\" -Force -ErrorAction SilentlyContinue
    "done" | Set-Content "$DepsDst\.stamp"
    Write-Host "All deps built."
}

function Invoke-Hap {
    Write-Host "=== Packaging HAP ==="
    $ohProject = "$Root\ohos"

    if (-not (Test-Path $Hvigorw)) {
        Write-Host "ERROR: hvigorw not found at $Hvigorw"
        return
    }

    # 清掉 DevEco Studio 可能遗留的错误环境变量，让 wrapper 自动检测
    $origNodeHome = $env:DEVECO_NODE_HOME
    $origSdkHome = $env:DEVECO_SDK_HOME
    $origPath = $env:PATH
    $env:DEVECO_NODE_HOME = $DevEcoNodeHome
    $env:DEVECO_SDK_HOME = "$SdkRoot\sdk"
    $env:PATH = "$DevEcoNodeHome;$SdkRoot\bin;$origPath"

    Push-Location $ohProject
    try {
        $mode = if ($BuildType -eq "release") { "release" } else { "debug" }
        $p = Start-Process -FilePath $Hvigorw -ArgumentList "--mode","module","-p","product=default","-p","buildMode=$mode","assembleHap" -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            Write-Host "hvigorw exited with code $($p.ExitCode)"
        }
        # 检查产物
        $hapSrc = "$ohProject\entry\build\default\outputs\default\entry-default-unsigned.hap"
        if (Test-Path $hapSrc) {
            $hapDir = "$Root\out\ohos\$Arch"
            New-Item -ItemType Directory -Force -Path $hapDir | Out-Null
            $hapDest = "$hapDir\krkrsdl3_${Arch}_${BuildType}.hap"
            Copy-Item $hapSrc $hapDest -Force
            $info = Get-Item $hapDest
            Write-Host "HAP: $hapDest ($([math]::Round($info.Length/1KB,1))KB)"
        } else {
            Write-Host "WARNING: HAP not found at $hapSrc"
        }
    } finally {
        Pop-Location
        $env:DEVECO_NODE_HOME = $origNodeHome
        $env:DEVECO_SDK_HOME = $origSdkHome
        $env:PATH = $origPath
    }
}

# ================================================================
#  ENTRY
# ================================================================

Write-Host "=== krkrsdl3 OHOS ==="
Write-Host "    CMD: $Target | ARCH: $Arch | TYPE: $BuildType"
Write-Host "    SDK: $SDK"

if (-not (Test-Path $SDK)) { Write-Host "ERROR: SDK not found at $SDK"; exit 1 }

try {
    switch ($Target) {
        "full"  { Invoke-Deps; Invoke-Hap }
        "deps"  { Invoke-Deps }
        "hap"   { Invoke-Hap }
        "clean" { Remove-Item -Force -Recurse "$Root\out\ohos" -ErrorAction SilentlyContinue; Write-Host "Cleaned." }
    }
} catch {
    Write-Host "ERROR: $_"
    exit 1
}
