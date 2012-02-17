#!/bin/sh
#
# bundle-tool.sh
# SimulatorLauncher
#
# Ported from Erica Sadun's AppleScript bundler
# bastardized by Ashley Towns <ashleyis@mogeneration.com>
# further bastardized by Crufty

PLIST_CMD="/usr/libexec/PlistBuddy"
RSYNC="/usr/bin/rsync -aE"

EMBED_DIR="Contents/Resources/EmbeddedApp"
ICNS_FILE="Contents/Resources/Launcher.icns"

# Exit constants understood by wrapping GUIs
SUCCESS=0
USAGE_ERROR=1
SOURCE_APP_MISSING=2
TEMPLATE_MISSING=3
INVALID_DEVICE_FAMILY=4
SOURCE_APP_INVALID=4
DESTINATION_WRITE_FAILED=5

# Default search for Launcher.app in path where we were launched from
ORIGINAL_PATH="$(pwd)"
cd "$(dirname $0)"
BIN_PATH="$(pwd)"
cd "${ORIGINAL_PATH}"
TEMPLATE_APP="${BIN_PATH}/Launcher.app"
if [ ! -d "${TEMPLATE_APP}" ]
then
	TEMPLATE_APP="/usr/local/share/simbundler/Launcher.app"
fi

# Print Usage
print_usage () {
    echo "Usage: $0 [--help] [--source-app <app>] [--dest <path>]"
}

# Check if the previous command completed successfully. If not, echo the
# provided message and exit.
#
# Arguments: <msg> <exit code>
check_error () {
    local msg=$0
    local code=$1

    if [ $? != 0 ]; then
        echo "${msg}"
        exit "${code}"
    fi
}

# Parse the application plist and set various globals
parse_plist () {
	PLIST="${APP}/Info.plist"

	if [ ! -f "${PLIST}" ]; then
		echo "Missing application plist"
		exit ${SOURCE_APP_INVALID}
	fi

	# Read the display name
	APP_NAME=`${PLIST_CMD} -c "Print CFBundleDisplayName" "${PLIST}"`
	APP_BUNDLE_ID=`${PLIST_CMD} -c "Print CFBundleIdentifier" "${PLIST}"`
	APP_ICON=`${PLIST_CMD} -c "Print CFBundleIconFile" "${PLIST}" 2>/dev/null`
	DEV_ARCH=`${PLIST_CMD} -c "Print UIDeviceFamily:0" "${PLIST}" 2>/dev/null`

	if [ -z "${APP_NAME}" ]; then
		echo "${APP} is missing a valid CFBundleDisplayName"
		exit ${SOURCE_APP_INVALID}
	fi

	if [ -z "${APP_BUNDLE_ID}" ]; then
		echo "${APP} is missing a valid CFBundleIdentifier"
		exit ${SOURCE_APP_INVALID}
	fi

	# Convert to absolute path
	if [ -z "${APP_ICON}" ]; then
		# Defaults to Icon.png
		APP_ICON="${APP}/Icon.png"
	else
		APP_ICON="${APP}/${APP_ICON}"
	fi

	if [ "${DEV_ARCH}" == "1" ]
	then
		DEVICE_FAMILY="iPhone"
	else
		DEVICE_FAMILY="iPad"
	fi
}

# Find a unique destination path
compute_dest_path () {
	local dest="`dirname "${APP}"`/${APP_NAME} (iPhone Simulator)"
	local suffix=""

	# Find a unique name
	while [ -e "${dest}${suffix}.app" ]; do
		if [ -z ${suffix} ]; then
			suffix=" 1"
		else
			suffix=" `expr ${suffix} + 1`"
		fi
	done

	# Found it
	APP_DEST="${dest}${suffix}.app"
}

# Populate the destination
populate_dest_path () {
	mkdir -p "${APP_DEST}"
	check_error "Could not create destination directory" ${DESTINATION_WRITE_FAILED}

	${RSYNC} --exclude ${EMBED_DIR} "${TEMPLATE_APP}"/ "${APP_DEST}"/
	check_error "Could not populate destination directory" ${DESTINATION_WRITE_FAILED}

	# Copy the source app to the destination
	mkdir -p "${APP_DEST}/${EMBED_DIR}"
	check_error "Could not create embedded app destination directory" ${DESTINATION_WRITE_FAILED}
	local app_dirname=`dirname "${APP}"`
	tar -C "${app_dirname}" -cf - "`basename \"${APP}\"`" | tar -C "${APP_DEST}/${EMBED_DIR}" -xf -
	check_error "Could not populate embedded app destination directory" ${DESTINATION_WRITE_FAILED}
}

# Convert and insert the target application's icon and bundle identifier
populate_meta_data () {
	local wrapper_plist="${APP_DEST}/Contents/Info.plist"

	# Set the bundle identifier (original + .launchsim suffix)
	${PLIST_CMD} -c "Set :CFBundleIdentifier ${APP_BUNDLE_ID}.launchsim" "${wrapper_plist}"
	check_error "Failed to modify wrapper application's plist" ${DESTINATION_WRITE_FAILED}

	# Convert the embedded application's icon
	if [ -f "${APP_ICON}" ]; then
		local resampled=`mktemp /tmp/${tempfoo}.XXXXXX`
		check_error "Could not create temporary file for Icon resampling" ${DESTINATION_WRITE_FAILED}

		# Convert the icon. If we were really cool, we'd support applying the same effects that Apple
		# does. Use ImageMagick if available.
		local convert=`which convert`
		if [ ! -z "$convert" ]; then
			$convert "${APP_ICON}" -resample 128x128 "${APP_DEST}/${ICNS_FILE}"
		else
			/usr/bin/sips --resampleWidth 128 -s format icns "${APP_ICON}" --out "${APP_DEST}/${ICNS_FILE}"
		fi
		check_error "Failed to convert application icon" ${DESTINATION_WRITE_FAILED}

		# Clean up
		rm -f "${resampled}"
	fi

    # Set the default device family
    if [ ! -z "${DEVICE_FAMILY}" ]; then
        if [ "${DEVICE_FAMILY}" = "iPhone" ]; then
            local family="1"
        elif [ "${DEVICE_FAMILY}" = "iPad" ]; then
            local family="2"
        else
            # A literal device family value
            local family="${DEVICE_FAMILY}"
        fi

        ${PLIST_CMD} -c "Add PLDefaultUIDeviceFamily string ${DEVICE_FAMILY}" "${wrapper_plist}"
        check_error "Failed to set device family in application's plist" ${DESTINATION_WRITE_FAILED}
    fi
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case $1 in
    --source-app)
        shift
        if [ ! -d "$1" ]; then
            echo "No app found at ${1}."
            exit 1
        fi
        APP="$1"
        shift
        ;;
    --dest)
        shift
        DEST_PATH="$1"
        shift
        ;;
    --help)
        print_usage
        exit 0
        ;;
    *)
        echo "Unknown option $1" 1>&2
        print_usage
        exit ${USAGE_ERROR}
    esac
done

if [ -z "${APP}" ]; then
    echo "--source-app must be supplied"
    print_usage
    exit ${USAGE_ERROR}
fi

# Check file paths
if [ ! -d "${APP}" ]; then
	echo "No app found at ${APP}."
	exit ${SOURCE_APP_MISSING}
fi

if [ ! -d "${TEMPLATE_APP}" ]; then
	echo "No template app found at ${TEMPLATE_APP}."
	exit ${SOURCE_APP_MISSING}
fi

# Parse the plist
parse_plist
echo "App Name: ${APP_NAME}"

if [ -z "${DEST_PATH}" ]
then
	# Compute the destination path
	compute_dest_path
else
	DEST_PATH=`echo "${DEST_PATH}" | sed -e 's/\.app$//'`.app
	if [ -d "${DEST_PATH}" ]
	then
		rm -rf "${DEST_PATH}"
	fi
	APP_DEST="${DEST_PATH}"
fi
echo "Destination: ${APP_DEST}"

# Populate the destination with the template data
populate_dest_path

# Add meta-data
populate_meta_data
