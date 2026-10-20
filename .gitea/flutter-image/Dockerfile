# Runner image for the `simpastil-flutter` job label.
#
# The upstream Cirrus Labs image only tracks Flutter releases with a delay, so
# this layers the SHA-256-verified Flutter SDK the repository pins in `.fvmrc`
# and the Android SDK pieces the Gradle build needs onto the digest-pinned
# upstream image. User, PATH and permissions of the base image stay unchanged (FLUTTER_VERSION is updated):
# the jobs run as root with Java 21 and the Android SDK at /opt/android-sdk-linux.
#
# Build, push and record the digest as described in docs/RELEASE.md, "Flutter
# runner image". Keep FLUTTER_SDK_VERSION in step with `.fvmrc`; the policy gate
# scripts/check-locks-and-digests.sh checks that. The ARG is not named
# FLUTTER_VERSION because the base image sets that variable in its ENV, which
# would win over an ARG default.

FROM ghcr.io/cirruslabs/flutter:3.41.5@sha256:5120236042c0a04d831c69fc41f0d56462d145d3b0078fdd07b50d655bbec985 AS flutter-sdk

ARG FLUTTER_SDK_VERSION=3.47.7
# From https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json
ARG FLUTTER_SHA256=af7455f540df951184c7953fbe3cf884766e7541dacf8571f9f582db03dd6230

RUN set -eu; \
    archive="flutter_linux_${FLUTTER_SDK_VERSION}-stable.tar.xz"; \
    curl --fail --silent --show-error --location \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${archive}" \
      --output "/tmp/${archive}"; \
    printf '%s  %s\n' "${FLUTTER_SHA256}" "/tmp/${archive}" | sha256sum --check --strict; \
    mkdir /sdks-new; \
    tar -xJf "/tmp/${archive}" --no-same-owner -C /sdks-new; \
    rm -f "/tmp/${archive}"

FROM ghcr.io/cirruslabs/flutter:3.41.5@sha256:5120236042c0a04d831c69fc41f0d56462d145d3b0078fdd07b50d655bbec985

ARG FLUTTER_SDK_VERSION=3.47.7
# Flutter 3.47 builds against Android 37 (permission_handler_android); some
# plugins still compile against 34 and 35. The NDK and CMake are the ones the
# Android Gradle build selects. Installing them here keeps the jobs from
# downloading SDK pieces at run time. build-tools 36.0.0 is already in the base.
ARG ANDROID_PLATFORM_PACKAGE="platforms;android-37.0"
ARG ANDROID_PLUGIN_PLATFORM_PACKAGES="platforms;android-34 platforms;android-35"
ARG ANDROID_NDK_PACKAGE="ndk;28.2.13676358"
ARG ANDROID_CMAKE_PACKAGE="cmake;3.22.1"

RUN rm -rf /sdks/flutter
COPY --from=flutter-sdk /sdks-new/flutter /sdks/flutter

# The certificate pinning tests generate their TLS fixtures with the openssl
# command line tool at test time. The sqlite3 package compiles its bundled
# SQLite3MC for the host when `flutter test` runs, and native_toolchain_c looks
# for clang, llvm-ar and ld.lld on PATH for a Linux host.
RUN set -eu; \
    apt-get update; \
    apt-get install --yes --no-install-recommends openssl clang lld llvm; \
    rm -rf /var/lib/apt/lists/*; \
    openssl version; \
    clang --version; \
    command -v llvm-ar ld.lld

RUN set -eu; \
    yes | sdkmanager --licenses >/dev/null; \
    sdkmanager --install "${ANDROID_PLATFORM_PACKAGE}" ${ANDROID_PLUGIN_PLATFORM_PACKAGES} \
      "${ANDROID_NDK_PACKAGE}" "${ANDROID_CMAKE_PACKAGE}"; \
    flutter config --no-analytics --no-cli-animations >/dev/null; \
    flutter precache --android; \
    flutter --version

ENV FLUTTER_VERSION=${FLUTTER_SDK_VERSION}

LABEL org.opencontainers.image.title="simpastil-flutter" \
      org.opencontainers.image.description="Flutter ${FLUTTER_SDK_VERSION} runner image for the Simpastil CI and release jobs"
