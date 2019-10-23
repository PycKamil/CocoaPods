require 'cocoapods/xcode'

module Pod
  module Generator
    class EmbedFrameworksScript
      # @return [Hash{String => Array<FrameworkPaths>}] Multiple lists of frameworks per
      #         configuration.
      #
      attr_reader :frameworks_by_config

      # @return [Hash{String => Array<Pod::Xcode::XCFramework>}] Multiple lists of xcframeworks per
      #         configuration.
      #
      attr_reader :xcframeworks_by_config

      # @return [Pathname] the root directory of the sandbox
      #
      attr_reader :sandbox_root

      # @return [Pod::Platform] the platform of the target on which this script will run
      #
      attr_reader :platform

      # @param  [Hash{String => Array<FrameworkPaths>] frameworks_by_config
      #         @see #frameworks_by_config
      #
      # @param  [Hash{String => Array<Pod::Xcode::XCFramework>] xcframeworks_by_config
      #         @see #xcframeworks_by_config
      #
      # @param  [Pathname] sandbox_root
      #         the sandbox root of the installation
      #
      def initialize(frameworks_by_config, xcframeworks_by_config, sandbox_root, platform)
        @frameworks_by_config = frameworks_by_config
        @xcframeworks_by_config = xcframeworks_by_config
        @sandbox_root = sandbox_root
        @platform = platform
      end

      # Saves the resource script to the given pathname.
      #
      # @param  [Pathname] pathname
      #         The path where the embed frameworks script should be saved.
      #
      # @return [void]
      #
      def save_as(pathname)
        pathname.open('w') do |file|
          file.puts(script)
        end
        File.chmod(0755, pathname.to_s)
      end

      # @return [String] The contents of the embed frameworks script.
      #
      def generate
        script
      end

      private

      # @!group Private Helpers

      # @return [String] The contents of the embed frameworks script.
      #
      def script
        script = <<-SH.strip_heredoc
          #!/bin/sh
          set -e
          set -u
          set -o pipefail

          function on_error {
            echo "$(realpath -mq "${0}"):$1: error: Unexpected failure"
          }
          trap 'on_error $LINENO' ERR

          if [ -z ${FRAMEWORKS_FOLDER_PATH+x} ]; then
            # If FRAMEWORKS_FOLDER_PATH is not set, then there's nowhere for us to copy
            # frameworks to, so exit 0 (signalling the script phase was successful).
            exit 0
          fi

          echo "mkdir -p ${CONFIGURATION_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
          mkdir -p "${CONFIGURATION_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

          COCOAPODS_PARALLEL_CODE_SIGN="${COCOAPODS_PARALLEL_CODE_SIGN:-false}"
          SWIFT_STDLIB_PATH="${DT_TOOLCHAIN_DIR}/usr/lib/swift/${PLATFORM_NAME}"

          # Used as a return value for each invocation of `strip_invalid_archs` function.
          STRIP_BINARY_RETVAL=0

          # This protects against multiple targets copying the same framework dependency at the same time. The solution
          # was originally proposed here: https://lists.samba.org/archive/rsync/2008-February/020158.html
          RSYNC_PROTECT_TMP_FILES=(--filter "P .*.??????")

          # Copies and strips a vendored framework
          install_framework()
          {
            if [ -r "${BUILT_PRODUCTS_DIR}/$1" ]; then
              local source="${BUILT_PRODUCTS_DIR}/$1"
            elif [ -r "${BUILT_PRODUCTS_DIR}/$(basename "$1")" ]; then
              local source="${BUILT_PRODUCTS_DIR}/$(basename "$1")"
            elif [ -r "$1" ]; then
              local source="$1"
            fi

            local destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"

            if [ -L "${source}" ]; then
              echo "Symlinked..."
              source="$(readlink "${source}")"
            fi

            # Use filter instead of exclude so missing patterns don't throw errors.
            echo "rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter \\"- CVS/\\" --filter \\"- .svn/\\" --filter \\"- .git/\\" --filter \\"- .hg/\\" --filter \\"- Headers\\" --filter \\"- PrivateHeaders\\" --filter \\"- Modules\\" \\"${source}\\" \\"${destination}\\""
            rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${source}" "${destination}"

            local basename
            basename="$(basename -s .framework "$1")"
            binary="${destination}/${basename}.framework/${basename}"

            if ! [ -r "$binary" ]; then
              binary="${destination}/${basename}"
            elif [ -L "${binary}" ]; then
              echo "Destination binary is symlinked..."
              dirname="$(dirname "${binary}")"
              binary="${dirname}/$(readlink "${binary}")"
            fi

            # Strip invalid architectures so "fat" simulator / device frameworks work on device
            if [[ "$(file "$binary")" == *"dynamically linked shared library"* ]]; then
              strip_invalid_archs "$binary"
            fi

            # Resign the code if required by the build settings to avoid unstable apps
            code_sign_if_enabled "${destination}/$(basename "$1")"

            # Embed linked Swift runtime libraries. No longer necessary as of Xcode 7.
            if [ "${XCODE_VERSION_MAJOR}" -lt 7 ]; then
              local swift_runtime_libs
              swift_runtime_libs=$(xcrun otool -LX "$binary" | grep --color=never @rpath/libswift | sed -E s/@rpath\\\\/\\(.+dylib\\).*/\\\\1/g | uniq -u)
              for lib in $swift_runtime_libs; do
                echo "rsync -auv \\"${SWIFT_STDLIB_PATH}/${lib}\\" \\"${destination}\\""
                rsync -auv "${SWIFT_STDLIB_PATH}/${lib}" "${destination}"
                code_sign_if_enabled "${destination}/${lib}"
              done
            fi
          }

          # Copies and strips a vendored dSYM
          install_dsym() {
            local source="$1"
            if [ -r "$source" ]; then
              # Copy the dSYM into the targets temp dir.
              echo "rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter \\"- CVS/\\" --filter \\"- .svn/\\" --filter \\"- .git/\\" --filter \\"- .hg/\\" --filter \\"- Headers\\" --filter \\"- PrivateHeaders\\" --filter \\"- Modules\\" \\"${source}\\" \\"${DERIVED_FILES_DIR}\\""
              rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${source}" "${DERIVED_FILES_DIR}"

              local basename
              basename="$(basename -s .framework.dSYM "$source")"
              binary="${DERIVED_FILES_DIR}/${basename}.framework.dSYM/Contents/Resources/DWARF/${basename}"

              # Strip invalid architectures so "fat" simulator / device frameworks work on device
              if [[ "$(file "$binary")" == *"Mach-O "*"dSYM companion"* ]]; then
                strip_invalid_archs "$binary"
              fi

              if [[ $STRIP_BINARY_RETVAL == 1 ]]; then
                # Move the stripped file into its final destination.
                echo "rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter \\"- CVS/\\" --filter \\"- .svn/\\" --filter \\"- .git/\\" --filter \\"- .hg/\\" --filter \\"- Headers\\" --filter \\"- PrivateHeaders\\" --filter \\"- Modules\\" \\"${DERIVED_FILES_DIR}/${basename}.framework.dSYM\\" \\"${DWARF_DSYM_FOLDER_PATH}\\""
                rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${DERIVED_FILES_DIR}/${basename}.framework.dSYM" "${DWARF_DSYM_FOLDER_PATH}"
              else
                # The dSYM was not stripped at all, in this case touch a fake folder so the input/output paths from Xcode do not reexecute this script because the file is missing.
                touch "${DWARF_DSYM_FOLDER_PATH}/${basename}.framework.dSYM"
              fi
            fi
          }

          # Copies the bcsymbolmap files of a vendored framework
          install_bcsymbolmap() {
              local bcsymbolmap_path="$1"
              local destination="${BUILT_PRODUCTS_DIR}"
              echo "rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter \"- CVS/\" --filter \"- .svn/\" --filter \"- .git/\" --filter \"- .hg/\" --filter \"- Headers\" --filter \"- PrivateHeaders\" --filter \"- Modules\" \"${bcsymbolmap_path}\" \"${destination}\""
              rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" --filter "- Headers" --filter "- PrivateHeaders" --filter "- Modules" "${bcsymbolmap_path}" "${destination}"
          }

          # Signs a framework with the provided identity
          code_sign_if_enabled() {
            if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" -a "${CODE_SIGNING_REQUIRED:-}" != "NO" -a "${CODE_SIGNING_ALLOWED}" != "NO" ]; then
              # Use the current code_sign_identity
              echo "Code Signing $1 with Identity ${EXPANDED_CODE_SIGN_IDENTITY_NAME}"
              local code_sign_cmd="/usr/bin/codesign --force --sign ${EXPANDED_CODE_SIGN_IDENTITY} ${OTHER_CODE_SIGN_FLAGS:-} --preserve-metadata=identifier,entitlements '$1'"

              if [ "${COCOAPODS_PARALLEL_CODE_SIGN}" == "true" ]; then
                code_sign_cmd="$code_sign_cmd &"
              fi
              echo "$code_sign_cmd"
              eval "$code_sign_cmd"
            fi
          }

          # Strip invalid architectures
          strip_invalid_archs() {
            binary="$1"
            # Get architectures for current target binary
            binary_archs="$(lipo -info "$binary" | rev | cut -d ':' -f1 | awk '{$1=$1;print}' | rev)"
            # Intersect them with the architectures we are building for
            intersected_archs="$(echo ${ARCHS[@]} ${binary_archs[@]} | tr ' ' '\\n' | sort | uniq -d)"
            # If there are no archs supported by this binary then warn the user
            if [[ -z "$intersected_archs" ]]; then
              echo "warning: [CP] Vendored binary '$binary' contains architectures ($binary_archs) none of which match the current build architectures ($ARCHS)."
              STRIP_BINARY_RETVAL=0
              return
            fi
            stripped=""
            for arch in $binary_archs; do
              if ! [[ "${ARCHS}" == *"$arch"* ]]; then
                # Strip non-valid architectures in-place
                lipo -remove "$arch" -output "$binary" "$binary"
                stripped="$stripped $arch"
              fi
            done
            if [[ "$stripped" ]]; then
              echo "Stripped $binary of architectures:$stripped"
            fi
            STRIP_BINARY_RETVAL=1
          }

          install_xcframework() {
            local basepath="$1"
            shift
            local paths=("$@")
            
            # Locate the correct slice of the .xcframework for the current architectures
            local target_path=""
            for i in ${!paths[@]}; do
              if [[ "${paths[$i]}" == *"$arch"* ]]; then
                # Found a matching slice
                target_path=${paths[$i]}
                break;
              fi
            done
            
            if [[ -z "$target_path" ]]; then
              echo "warning: [CP] Unable to find matching .xcframework slice in '${paths[@]}' for the current build architectures ($ARCHS)."
              return
            fi
            
            install_framework "$target_path"
          }

        SH
        contents_by_config = Hash.new do |hash, key|
          hash[key] = ""
        end
        frameworks_by_config.each do |config, frameworks_with_dsyms|
          next if frameworks_with_dsyms.empty?
          frameworks_with_dsyms.each do |framework_with_dsym|
            contents_by_config[config] << %(  install_framework "#{framework_with_dsym.source_path}"\n)
            # Vendored frameworks might have a dSYM file next to them so ensure its copied. Frameworks built from
            # sources will have their dSYM generated and copied by Xcode.
            contents_by_config[config] << %(  install_dsym "#{framework_with_dsym.dsym_path}"\n) unless framework_with_dsym.dsym_path.nil?
            unless framework_with_dsym.bcsymbolmap_paths.nil?
              framework_with_dsym.bcsymbolmap_paths.each do |bcsymbolmap_path|
                contents_by_config[config] << %(  install_bcsymbolmap "#{bcsymbolmap_path}"\n)
              end
            end
          end
        end
        xcframeworks_by_config.each do |config, xcframeworks|
          next if xcframeworks.empty?
          xcframeworks.each do |xcframework|
            # It's possible for an .xcframework to include slices of different linkages,
            # so we must select only dynamic slices to pass to the script
            slices = xcframework.slices
              .select { |slice| slice.platform.symbolic_name == platform.symbolic_name }
              .select { |slice| Xcode::LinkageAnalyzer.dynamic_binary?(slice.library_path) }
            next if slices.empty?
            relative_path = xcframework.path.relative_path_from(sandbox_root)
            args = [shell_escape("${PODS_ROOT}/#{relative_path}")]
            slices.each do |slice|
              args << shell_escape(slice.path.relative_path_from(xcframework.path))
            end
            # We pass two arrays to install_xcframework - a nested list of archs, and a list of paths that
            # contain frameworks for those archs
            contents_by_config[config] << %(  install_xcframework #{args.join(" ")}\n)
          end
        end

        script << "\n" unless contents_by_config.empty?
        contents_by_config.keys.sort.each do |config|
          contents = contents_by_config[config]
          next if contents.empty?
          script << %(if [[ "$CONFIGURATION" == "#{config}" ]]; then\n)
          script << contents
          script << "fi\n"
        end

        script << <<-SH.strip_heredoc
        if [ "${COCOAPODS_PARALLEL_CODE_SIGN}" == "true" ]; then
          wait
        fi
        SH
        script
      end

      def shell_escape(value)
        "\"#{value}\""
      end
    end
  end
end
