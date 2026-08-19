
export TARGET := iphone:clang:latest:14.0
export ARCHS := arm64
export SDKVERSION := 14.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = krkrsdl3

krkrsdl3_FILES = \
	../cpp/core/archive/TextStream.cpp \
	../cpp/core/archive/TVPArchive.cpp \
	../cpp/core/archive/TVPStorage.cpp \
	../cpp/core/archive/UtilStreams.cpp \
	../cpp/core/archive/XP3Archive.cpp \
	../cpp/core/archive/encoding/gbk2unicode.c \
	../cpp/core/archive/encoding/jis2unicode.c \
	../cpp/core/main/NativeEventQueue.cpp \
	../cpp/core/main/SystemControl.cpp \
	../cpp/core/main/TVPApplication.cpp \
	../cpp/core/main/TVPEvent.cpp \
	../cpp/core/main/TVPSystem.cpp \
	../cpp/core/main/WindowIntf.cpp \
	../cpp/core/media/font/CharacterData.cpp \
	../cpp/core/media/font/FreeTypeFontRasterizer.cpp \
	../cpp/core/media/font/FreeTypeImp.cpp \
	../cpp/core/media/font/PrerenderedFont.cpp \
	../cpp/core/media/font/TVPFont.cpp \
	../cpp/core/media/image/BitmapInfomation.cpp \
	../cpp/core/media/image/GraphicsLoadThread.cpp \
	../cpp/core/media/image/LoadBMP.cpp \
	../cpp/core/media/image/LoadTLG.cpp \
	../cpp/core/media/image/SaveTLG5.cpp \
	../cpp/core/media/image/SaveTLG6.cpp \
	../cpp/core/media/image/TVPGraphicsLoader.cpp \
	../cpp/core/media/sound/RIFFWaveDecoder.cpp \
	../cpp/core/media/sound/TVPWaveManager.cpp \
	../cpp/core/media/sound/WaveDecodeThread.cpp \
	../cpp/core/media/sound/WaveLoopManager.cpp \
	../cpp/core/media/sound/WaveSegmentQueue.cpp \
	../cpp/core/msg/TVPDebug.cpp \
	../cpp/core/msg/TVPMsg.cpp \
	../cpp/core/render/gl/blend_function.cpp \
	../cpp/core/render/gl/tvpgl.cpp \
	../cpp/core/render/ComplexRect.cpp \
	../cpp/core/render/DrawDevice.cpp \
	../cpp/core/render/LayerBitmap.cpp \
	../cpp/core/render/LayerManager.cpp \
	../cpp/core/render/LayerTreeOwner.cpp \
	../cpp/core/render/MainWindowLayer.cpp \
	../cpp/core/render/RenderManager.cpp \
	../cpp/core/render/TransIntf.cpp \
	../cpp/core/render/TVPColor.cpp \
	cpp-ios/core/render/TVPCompositor.cpp \
	../cpp/core/script/tjsNativeAsyncTrigger.cpp \
	../cpp/core/script/tjsNativeBasicDrawDevice.cpp \
	../cpp/core/script/tjsNativeBitmap.cpp \
	../cpp/core/script/tjsNativeBitmapLayerTreeOwner.cpp \
	../cpp/core/script/tjsNativeCDDASoundBuffer.cpp \
	../cpp/core/script/tjsNativeClipboard.cpp \
	../cpp/core/script/tjsNativeDebug.cpp \
	../cpp/core/script/tjsNativeFont.cpp \
	../cpp/core/script/tjsNativeImageFunction.cpp \
	../cpp/core/script/tjsNativeKAGParser.cpp \
	../cpp/core/script/tjsNativeLayer.cpp \
	../cpp/core/script/tjsNativeMenuItem.cpp \
	../cpp/core/script/tjsNativeMIDISoundBuffer.cpp \
	../cpp/core/script/tjsNativePad.cpp \
	../cpp/core/script/tjsNativePhaseVocoder.cpp \
	../cpp/core/script/tjsNativePlugins.cpp \
	../cpp/core/script/tjsNativeRect.cpp \
	../cpp/core/script/tjsNativeScript.cpp \
	../cpp/core/script/tjsNativeStorages.cpp \
	../cpp/core/script/tjsNativeSystem.cpp \
	../cpp/core/script/tjsNativeTimer.cpp \
	../cpp/core/script/tjsNativeVideoOverlay.cpp \
	../cpp/core/script/tjsNativeWaveSoundBuffer.cpp \
	../cpp/core/script/tjsNativeWindow.cpp \
	../cpp/core/script/TVPScript.cpp \
	../cpp/core/utils/PhaseVocoderDSP.cpp \
	../cpp/core/utils/Random.cpp \
	../cpp/core/utils/RealFFT.cpp \
	../cpp/core/utils/ResampleImage.cpp \
	cpp-ios/core/utils/TVPSettings.cpp \
	../cpp/core/utils/TVPTimer.cpp \
	../cpp/core/utils/VelocityTracker.cpp \
	../cpp/core/utils/WaveFormatConverter.cpp \
	../cpp/core/utils/WeightFunctor.cpp \
	../cpp/core/utils/math/md5.c \
	../cpp/core/media/movie/krmovie.cpp \
	../cpp/tjs2/tjs.cpp \
	../cpp/tjs2/tjs.tab.cpp \
	../cpp/tjs2/tjsArray.cpp \
	../cpp/tjs2/tjsBinarySerializer.cpp \
	../cpp/tjs2/tjsByteCodeLoader.cpp \
	../cpp/tjs2/tjsCompileControl.cpp \
	cpp-ios/tjs2/tjsConfig.cpp \
	../cpp/tjs2/tjsConstArrayData.cpp \
	../cpp/tjs2/tjsDate.cpp \
	../cpp/tjs2/tjsdate.tab.cpp \
	../cpp/tjs2/tjsDateParser.cpp \
	../cpp/tjs2/tjsDebug.cpp \
	../cpp/tjs2/tjsDictionary.cpp \
	../cpp/tjs2/tjsDisassemble.cpp \
	../cpp/tjs2/tjsError.cpp \
	../cpp/tjs2/tjsException.cpp \
	../cpp/tjs2/tjsGlobalStringMap.cpp \
	../cpp/tjs2/tjsInterCodeExec.cpp \
	../cpp/tjs2/tjsInterCodeGen.cpp \
	../cpp/tjs2/tjsInterface.cpp \
	../cpp/tjs2/tjsLex.cpp \
	../cpp/tjs2/tjsMath.cpp \
	../cpp/tjs2/tjsMessage.cpp \
	../cpp/tjs2/tjsMT19937ar-cok.cpp \
	../cpp/tjs2/tjsNamespace.cpp \
	../cpp/tjs2/tjsNative.cpp \
	../cpp/tjs2/tjsObject.cpp \
	../cpp/tjs2/tjsObjectExtendable.cpp \
	../cpp/tjs2/tjsOctPack.cpp \
	../cpp/tjs2/tjspp.tab.cpp \
	../cpp/tjs2/tjsRandomGenerator.cpp \
	../cpp/tjs2/tjsRegExp.cpp \
	../cpp/tjs2/tjsScriptBlock.cpp \
	../cpp/tjs2/tjsScriptCache.cpp \
	../cpp/tjs2/tjsString.cpp \
	../cpp/tjs2/tjsUtils.cpp \
	../cpp/tjs2/tjsVariant.cpp \
	../cpp/tjs2/tjsVariantString.cpp \
	../cpp/plugins/ncbind/ncbind.cpp \
	../cpp/plugins/addFont.cpp \
	../cpp/plugins/AlphaMovie.cpp \
	../cpp/plugins/csvParser.cpp \
	../cpp/plugins/dirlist.cpp \
	../cpp/plugins/expat.cpp \
	../cpp/plugins/fftgraph.cpp \
	../cpp/plugins/fstat.cpp \
	../cpp/plugins/FuncStubs.cpp \
	../cpp/plugins/getabout.cpp \
	../cpp/plugins/getSample.cpp \
	../cpp/plugins/gfxEffect.cpp \
	../cpp/plugins/gfxFire.cpp \
	../cpp/plugins/json.cpp \
	../cpp/plugins/LayerExAreaAverage.cpp \
	../cpp/plugins/LayerExBase.cpp \
	../cpp/plugins/LayerExBTOA.cpp \
	../cpp/plugins/LayerExImage.cpp \
	../cpp/plugins/LayerExMovie.cpp \
	../cpp/plugins/LayerExPerspective.cpp \
	../cpp/plugins/LayerExRaster.cpp \
	../cpp/plugins/LayerExSave.cpp \
	../cpp/plugins/motionPlayer.cpp \
	../cpp/plugins/PackinOne.cpp \
	../cpp/plugins/saveStruct.cpp \
	../cpp/plugins/scriptsEx.cpp \
	../cpp/plugins/shrinkCopy.cpp \
	../cpp/plugins/textrender.cpp \
	../cpp/plugins/TVPPlugin.cpp \
	../cpp/plugins/varfile.cpp \
	../cpp/plugins/win32dialog.cpp \
	../cpp/plugins/windowEx.cpp \
	../cpp/plugins/wuopus.cpp \
	../cpp/plugins/wutcwf.cpp \
	../cpp/plugins/wuvorbis.cpp \
	../cpp/plugins/xp3filter.cpp \
	../cpp/plugins/DrawDeviceD3D/DrawDeviceD3D.cpp \
	cpp-ios/plugins/emoteplayer/emotefile.cpp \
	cpp-ios/plugins/emoteplayer/emoteplayer.cpp \
	cpp-ios/plugins/emoteplayer/emoteplayerclass.cpp \
	cpp-ios/plugins/emoteplayer/emoterunner.cpp \
	../cpp/plugins/extrans/extrans.cpp \
	../cpp/plugins/extrans/mosaic.cpp \
	../cpp/plugins/extrans/ripple.cpp \
	../cpp/plugins/extrans/rotatebase.cpp \
	../cpp/plugins/extrans/rotatetrans.cpp \
	../cpp/plugins/extrans/turn.cpp \
	../cpp/plugins/extrans/turntrans_table.cpp \
	../cpp/plugins/extrans/wave.cpp \
	../cpp/plugins/KAGParserEx/KAG.cpp \
	../cpp/plugins/KAGParserEx/KAGParserEx.cpp \
	../cpp/plugins/ExtKAGParser/ExtKAG.cpp \
	../cpp/plugins/ExtKAGParser/ExtKAGParser.cpp \
	../cpp/plugins/ExtKAGParser/TJSAry.cpp \
	../cpp/plugins/ExtKAGParser/TJSDic.cpp \
	../cpp/plugins/LayerExDraw/LayerExDraw.cpp \
	../cpp/plugins/psbfile/PSB.cpp \
	../cpp/plugins/psbfile/PSBData.cpp \
	../cpp/plugins/psbfile/PSBFile.cpp \
	../cpp/plugins/psbfile/PSBMedia.cpp \
	../cpp/plugins/sqlite3/extend.cpp \
	../cpp/plugins/sqlite3/sqlite3.c \
	cpp-ios/plugins/sqlite3/sqlite3.cpp \
	../cpp/plugins/sqlite3/xp3_vfs.cpp \
	../cpp/plugins/Kirikiroid2/kirikiroid2.cpp \
	../cpp/plugins/Kirikiroid2/minizip/unzip.c \
	../cpp/plugins/Kirikiroid2/minizip/ioapi.cpp \
	../cpp/plugins/Kirikiroid2/TARArchive.cpp \
	../cpp/plugins/Kirikiroid2/ZIPArchive.cpp \
	../cpp/plugins/Kirikiroid2/7zArchive.cpp \
	../cpp/plugins/Kirikiroid2/7zip/7zArcIn.c \
	../cpp/plugins/Kirikiroid2/7zip/7zDec.c \
	../cpp/plugins/Kirikiroid2/7zip/7zBuf.c \
	../cpp/plugins/Kirikiroid2/7zip/7zBuf2.c \
	../cpp/plugins/Kirikiroid2/7zip/7zStream.c \
	../cpp/plugins/Kirikiroid2/7zip/Aes.c \
	../cpp/plugins/Kirikiroid2/7zip/AesOpt.c \
	../cpp/plugins/Kirikiroid2/7zip/Alloc.c \
	../cpp/plugins/Kirikiroid2/7zip/Bcj2.c \
	../cpp/plugins/Kirikiroid2/7zip/Bcj2Enc.c \
	../cpp/plugins/Kirikiroid2/7zip/Blake2s.c \
	../cpp/plugins/Kirikiroid2/7zip/Bra.c \
	../cpp/plugins/Kirikiroid2/7zip/Bra86.c \
	../cpp/plugins/Kirikiroid2/7zip/BraIA64.c \
	../cpp/plugins/Kirikiroid2/7zip/BwtSort.c \
	../cpp/plugins/Kirikiroid2/7zip/CpuArch.c \
	../cpp/plugins/Kirikiroid2/7zip/Delta.c \
	../cpp/plugins/Kirikiroid2/7zip/HuffEnc.c \
	../cpp/plugins/Kirikiroid2/7zip/LzFind.c \
	../cpp/plugins/Kirikiroid2/7zip/LzFindMt.c \
	../cpp/plugins/Kirikiroid2/7zip/LzFindOpt.c \
	../cpp/plugins/Kirikiroid2/7zip/LzmaDec.c \
	../cpp/plugins/Kirikiroid2/7zip/Lzma2Dec.c \
	../cpp/plugins/Kirikiroid2/7zip/Lzma2DecMt.c \
	../cpp/plugins/Kirikiroid2/7zip/Lzma2Enc.c \
	../cpp/plugins/Kirikiroid2/7zip/LzmaEnc.c \
	../cpp/plugins/Kirikiroid2/7zip/LzmaLib.c \
	../cpp/plugins/Kirikiroid2/7zip/MtCoder.c \
	../cpp/plugins/Kirikiroid2/7zip/MtDec.c \
	../cpp/plugins/Kirikiroid2/7zip/Ppmd7.c \
	../cpp/plugins/Kirikiroid2/7zip/Ppmd7aDec.c \
	../cpp/plugins/Kirikiroid2/7zip/Ppmd7Dec.c \
	../cpp/plugins/Kirikiroid2/7zip/Ppmd7Enc.c \
	../cpp/plugins/Kirikiroid2/7zip/Ppmd8.c \
	../cpp/plugins/Kirikiroid2/7zip/Ppmd8Dec.c \
	../cpp/plugins/Kirikiroid2/7zip/Ppmd8Enc.c \
	../cpp/plugins/Kirikiroid2/7zip/Sha1.c \
	../cpp/plugins/Kirikiroid2/7zip/Sha1Opt.c \
	../cpp/plugins/Kirikiroid2/7zip/Sha256.c \
	../cpp/plugins/Kirikiroid2/7zip/Sha256Opt.c \
	../cpp/plugins/Kirikiroid2/7zip/Sort.c \
	../cpp/plugins/Kirikiroid2/7zip/SwapBytes.c \
	../cpp/plugins/Kirikiroid2/7zip/Threads.c \
	../cpp/plugins/Kirikiroid2/7zip/Xz.c \
	../cpp/plugins/Kirikiroid2/7zip/XzDec.c \
	../cpp/plugins/Kirikiroid2/7zip/XzEnc.c \
	../cpp/plugins/Kirikiroid2/7zip/XzIn.c \
	../cpp/plugins/Kirikiroid2/7zip/7zCrc.c \
	../cpp/plugins/Kirikiroid2/7zip/7zCrcOpt.c \
	../cpp/plugins/Kirikiroid2/7zip/XzCrc64.c \
	../cpp/plugins/Kirikiroid2/7zip/XzCrc64Opt.c \
	../cpp/plugins/Kirikiroid2/7zip/Xxh64.c \
	../cpp/plugins/Kirikiroid2/7zip/ZstdDec.c \
	../cpp/plugins/Kirikiroid2/7zip/Md5.c \
	../cpp/plugins/Kirikiroid2/7zip/Sha3.c \
	../cpp/plugins/Kirikiroid2/7zip/Sha512.c \
	../cpp/plugins/Kirikiroid2/7zip/Sha512Opt.c \
	../cpp/plugins/Kirikiroid2/LoadJPEG.cpp \
	../cpp/plugins/Kirikiroid2/LoadPNG.cpp \
	../cpp/plugins/Kirikiroid2/LoadWEBP.cpp \
	cpp-ios/environ/Platform.cpp \
	cpp-ios/environ/unix/unix_file.cpp \
	../cpp/environ/sdl3/sdl3_audio.cpp \
	../cpp/environ/sdl3/sdl3_dialog.cpp \
	cpp-ios/environ/sdl3/sdl3_entry.cpp \
	cpp-ios/environ/sdl3/sdl3_file.cpp \
	../cpp/environ/sdl3/sdl3_thread.cpp \
	../cpp/environ/sdl3/sdl3_utils.cpp \
	cpp-ios/environ/ios/ios_core.mm \
	cpp-ios/environ/ios/ios_video.mm \
	APP/AppBootstrap.m \
	APP/AppStartup.m \
	APP/SDKCompat.m \

ENGINE_DEFS = \
	-D_KRKRSDL3_IOS=1 \
	-D_KRKRSDL3_LIB=1 \
	-D_KRKRSDL3_USE_SDL3=1 \
	-DONIG_STATIC \
	-DPLUTOVG_BUILD_STATIC \
	-DSDL_MAIN_USE_CALLBACKS \
	-DGLM_ENABLE_EXPERIMENTAL

VCPKG_DIR = $(THEOS_PROJECT_DIR)/vcpkg-ios/arm64-ios

ENGINE_INCS = \
	-I$(VCPKG_DIR)/include \
	-I$(VCPKG_DIR)/include/webp \
	-I$(VCPKG_DIR)/include/opus \
	-I$(VCPKG_DIR)/include/plutovg \
	-Icpp-ios \
	-Icpp-ios/environ \
	-Icpp-ios/environ/ios \
	-I../cpp \
	-I../cpp/core \
	-I../cpp/core/archive \
	-I../cpp/core/main \
	-I../cpp/core/media \
	-I../cpp/core/media/font \
	-I../cpp/core/media/image \
	-I../cpp/core/media/movie \
	-I../cpp/core/media/sound \
	-I../cpp/core/msg \
	-I../cpp/core/render \
	-I../cpp/core/script \
	-I../cpp/core/utils \
	-I../cpp/core/utils/math \
	-I../cpp/environ \
	-I../cpp/environ/sdl3 \
	-I../cpp/environ/unix \
	-I../cpp/plugins \
	-I../cpp/plugins/sqlite3 \
	-I../cpp/tjs2

krkrsdl3_CFLAGS     = $(ENGINE_DEFS) $(ENGINE_INCS) -fno-objc-arc -O2 -Wno-deprecated-declarations -Wno-unused-variable -Wno-logical-op-parentheses -Wno-deprecated-builtins
krkrsdl3_CCFLAGS    = $(ENGINE_DEFS) $(ENGINE_INCS) -fno-objc-arc -O2 -Wno-deprecated-declarations -Wno-unused-variable -Wno-logical-op-parentheses -std=gnu++17
krkrsdl3_CXXFLAGS   = $(ENGINE_DEFS) $(ENGINE_INCS) -fno-objc-arc -O2 -Wno-deprecated-declarations -Wno-unused-variable -Wno-logical-op-parentheses -std=gnu++17
krkrsdl3_OBJCFLAGS  = $(ENGINE_DEFS) $(ENGINE_INCS) -fobjc-arc     -O2 -Wno-deprecated-declarations -Wno-unused-variable
krkrsdl3_OBJCCFLAGS = $(ENGINE_DEFS) $(ENGINE_INCS) -fno-objc-arc -O2 -Wno-deprecated-declarations -Wno-unused-variable -std=gnu++17

krkrsdl3_FRAMEWORKS = \
	UIKit \
	CoreGraphics \
	CoreText \
	CoreFoundation \
	CoreVideo \
	CoreMedia \
	AVFoundation \
	AVFAudio \
	AudioToolbox \
	CoreAudio \
	Metal \
	MetalKit \
	OpenAL \
	OpenGLES \
	QuartzCore \
	Accelerate \
	Security \
	Foundation \
	CFNetwork \
	SystemConfiguration \
	CoreBluetooth \
	CoreHaptics \
	CoreMotion \
	GameController \
	ImageIO \
	UniformTypeIdentifiers

krkrsdl3_LDFLAGS = -L$(VCPKG_DIR)/lib \
	-lSDL3_ttf -lSDL3 \
	-lfreetype -lpng16 -lz -lbz2 -lbrotlidec -lbrotlienc -lbrotlicommon \
	-ljpeg -lturbojpeg \
	-lwebpmux -lwebpdemux -lwebpdecoder -lwebp -lsharpyuv \
	-lvorbisfile -lvorbisenc -lvorbis -logg \
	-lopusfile -lopus \
	-lonig -lplutovg -lc++

krkrsdl3_INSTALL_PATH = /Applications/
krkrsdl3_BUNDLE_RESOURCE_DIRS = Res

include $(THEOS_MAKE_PATH)/application.mk
