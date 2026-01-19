vcpkg_check_linkage(ONLY_STATIC_LIBRARY)

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO webmproject/libvpx
    REF "v${VERSION}"
    SHA512 824fe8719e4115ec359ae0642f5e1cea051d458f09eb8c24d60858cf082f66e411215e23228173ab154044bafbdfbb2d93b589bb726f55b233939b91f928aae0
    HEAD_REF master
    PATCHES
        0003-add-uwp-v142-and-v143-support.patch
        0004-remove-library-suffixes.patch
)

if(CMAKE_HOST_WIN32)
    vcpkg_acquire_msys(MSYS_ROOT PACKAGES make perl)
    set(ENV{PATH} "${MSYS_ROOT}/usr/bin;$ENV{PATH}")
else()
    vcpkg_find_acquire_program(PERL)
    get_filename_component(PERL_EXE_PATH ${PERL} DIRECTORY)
    set(ENV{PATH} "$ENV{PATH}:${PERL_EXE_PATH}")
endif()

find_program(BASH NAME bash HINTS /bin /usr/bin REQUIRED NO_CACHE)

vcpkg_find_acquire_program(NASM)
get_filename_component(NASM_EXE_PATH ${NASM} DIRECTORY)
vcpkg_add_to_path(${NASM_EXE_PATH})

if(VCPKG_TARGET_IS_WINDOWS AND NOT VCPKG_TARGET_IS_MINGW)
    # ... (Windows 전용 코드 유지)
    # 생략 (이 부분은 수정하지 않음)
else()
    set(OPTIONS "--disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-pic")

    set(OPTIONS_DEBUG "--enable-debug-libs --enable-debug --prefix=${CURRENT_PACKAGES_DIR}/debug")
    set(OPTIONS_RELEASE "--prefix=${CURRENT_PACKAGES_DIR}")
    set(AS_NASM "--as=nasm")

    if(VCPKG_LIBRARY_LINKAGE STREQUAL "dynamic")
        set(OPTIONS "${OPTIONS} --disable-static --enable-shared")
    else()
        set(OPTIONS "${OPTIONS} --enable-static --disable-shared")
    endif()

    if("realtime" IN_LIST FEATURES)
        set(OPTIONS "${OPTIONS} --enable-realtime-only")
    endif()

    if("highbitdepth" IN_LIST FEATURES)
        set(OPTIONS "${OPTIONS} --enable-vp9-highbitdepth")
    endif()

    if(VCPKG_TARGET_ARCHITECTURE STREQUAL x86)
        set(LIBVPX_TARGET_ARCH "x86")
    elseif(VCPKG_TARGET_ARCHITECTURE STREQUAL x64)
        set(LIBVPX_TARGET_ARCH "x86_64")
    elseif(VCPKG_TARGET_ARCHITECTURE STREQUAL arm)
        set(LIBVPX_TARGET_ARCH "armv7")
    elseif(VCPKG_TARGET_ARCHITECTURE STREQUAL arm64)
        set(LIBVPX_TARGET_ARCH "arm64")
    else()
        message(FATAL_ERROR "libvpx does not support architecture ${VCPKG_TARGET_ARCHITECTURE}")
    endif()

    vcpkg_cmake_get_vars(cmake_vars_file)
    include("${cmake_vars_file}")

    # Set environment variables for configure
    if(VCPKG_DETECTED_CMAKE_C_COMPILER MATCHES "([^\/]*-)gcc$")
        message(STATUS "Cross-building for ${TARGET_TRIPLET} with ${CMAKE_MATCH_1}")
        set(ENV{CROSS} ${CMAKE_MATCH_1})
        unset(AS_NASM)
    else()
        set(ENV{CC} ${VCPKG_DETECTED_CMAKE_C_COMPILER})
        set(ENV{CXX} ${VCPKG_DETECTED_CMAKE_CXX_COMPILER})
        set(ENV{AR} ${VCPKG_DETECTED_CMAKE_AR})
        set(ENV{LD} ${VCPKG_DETECTED_CMAKE_LINKER})
        set(ENV{RANLIB} ${VCPKG_DETECTED_CMAKE_RANLIB})
        set(ENV{STRIP} ${VCPKG_DETECTED_CMAKE_STRIP})
    endif()

    if(VCPKG_TARGET_IS_MINGW)
        if(LIBVPX_TARGET_ARCH STREQUAL "x86")
            set(LIBVPX_TARGET "x86-win32-gcc")
        else()
            set(LIBVPX_TARGET "x86_64-win64-gcc")
        endif()
    elseif(VCPKG_TARGET_IS_LINUX)
        set(LIBVPX_TARGET "${LIBVPX_TARGET_ARCH}-linux-gcc")
    elseif(VCPKG_TARGET_IS_ANDROID)
        set(LIBVPX_TARGET "generic-gnu")
        if(VCPKG_TARGET_ARCHITECTURE STREQUAL x86)
            set(OPTIONS "${OPTIONS} --disable-sse4_1 --disable-avx --disable-avx2 --disable-avx512")
        elseif(VCPKG_TARGET_ARCHITECTURE STREQUAL x64)
            set(OPTIONS "${OPTIONS} --disable-avx --disable-avx2 --disable-avx512")
        elseif(VCPKG_TARGET_ARCHITECTURE STREQUAL arm)
            set(OPTIONS "${OPTIONS} --enable-thumb --disable-neon")
        elseif(VCPKG_TARGET_ARCHITECTURE STREQUAL arm64)
            set(OPTIONS "${OPTIONS} --enable-thumb")
        endif()
        set(ENV{AS} ${VCPKG_DETECTED_CMAKE_C_COMPILER})
        set(ENV{LDFLAGS} "${LDFLAGS} --target=${VCPKG_DETECTED_CMAKE_C_COMPILER_TARGET}")
        set(OPTIONS "${OPTIONS} --extra-cflags=--target=${VCPKG_DETECTED_CMAKE_C_COMPILER_TARGET} --extra-cxxflags=--target=${VCPKG_DETECTED_CMAKE_CXX_COMPILER_TARGET}")
        unset(AS_NASM)
    elseif(VCPKG_TARGET_IS_OSX)
        # ... (생략)
    else()
        set(LIBVPX_TARGET "generic-gnu")
    endif()

    set(MAKE_BINARY "make")

    # 모든 텍스트 파일의 줄바꿈을 강제로 LF로 변환 (바이너리 제외)
    if(NOT VCPKG_DETECTED_MSVC)
        message(STATUS "Fixing line endings in all source files...")
        vcpkg_execute_required_process(
            COMMAND find . -type f -not -path '*/.git/*' -exec grep -Iq . {} \; -exec sed -i "s/\\r$//" {} +
            WORKING_DIRECTORY "${SOURCE_PATH}"
            LOGNAME "fix-line-endings"
        )
    endif()

    if(NOT DEFINED VCPKG_BUILD_TYPE OR VCPKG_BUILD_TYPE STREQUAL "release")
        message(STATUS "Configuring libvpx for Release")
        file(MAKE_DIRECTORY "${CURRENT_BUILDTREES_DIR}/${TARGET_TRIPLET}-rel")
        vcpkg_execute_required_process(
            COMMAND ${BASH} --noprofile --norc "${SOURCE_PATH}/configure" --target=${LIBVPX_TARGET} ${OPTIONS} ${OPTIONS_RELEASE} ${AS_NASM}
            WORKING_DIRECTORY "${CURRENT_BUILDTREES_DIR}/${TARGET_TRIPLET}-rel"
            LOGNAME configure-${TARGET_TRIPLET}-rel
        )

        # 생성된 파일 줄바꿈 고치기
        vcpkg_execute_required_process(
            COMMAND find . -maxdepth 2 -type f -exec sed -i "s/\\r$//" {} +
            WORKING_DIRECTORY "${CURRENT_BUILDTREES_DIR}/${TARGET_TRIPLET}-rel"
            LOGNAME "fix-makefile-line-endings-rel"
        )

        message(STATUS "Building libvpx for Release")
        vcpkg_execute_required_process(
            COMMAND ${MAKE_BINARY} -j${VCPKG_CONCURRENCY}
            WORKING_DIRECTORY "${CURRENT_BUILDTREES_DIR}/${TARGET_TRIPLET}-rel"
            LOGNAME build-${TARGET_TRIPLET}-rel
        )
        
        # ... (설치 코드 생략)
    endif()
    # ... (디버그 코드 동일하게 수정)
endif()
