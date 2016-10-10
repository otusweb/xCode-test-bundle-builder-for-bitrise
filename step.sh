#!/bin/bash

THIS_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

set -e

#fail if any command fails in a pipe command (https://sipb.mit.edu/doc/safe-shell/)
set -o pipefail

#exit if an undeclared variable is used (http://kvz.io/blog/2013/11/21/bash-best-practices/)
set -o nounset

#=======================================
# Functions
#=======================================

RESTORE='\033[0m'
RED='\033[00;31m'
YELLOW='\033[00;33m'
BLUE='\033[00;34m'
GREEN='\033[00;32m'

function color_echo {
	color=$1
	msg=$2
	echo -e "${color}${msg}${RESTORE}"
}

function echo_fail {
	msg=$1
	echo
	color_echo "${RED}" "${msg}"
	exit 1
}

function echo_warn {
	msg=$1
	color_echo "${YELLOW}" "${msg}"
}

function echo_info {
	msg=$1
	echo
	color_echo "${BLUE}" "${msg}"
}

function echo_details {
	msg=$1
	echo "  ${msg}"
}

function echo_done {
	msg=$1
	color_echo "${GREEN}" "  ${msg}"
}

function validate_required_input {
	key=$1
	value=$2
	if [ -z "${value}" ] ; then
		echo_fail "[!] Missing required input: ${key}"
	fi
}

function validate_required_input_with_options {
	key=$1
	value=$2
	options=$3

	validate_required_input "${key}" "${value}"

	found="0"
	for option in "${options[@]}" ; do
		if [ "${option}" == "${value}" ] ; then
			found="1"
		fi
	done

	if [ "${found}" == "0" ] ; then
		echo_fail "Invalid input: (${key}) value: (${value}), valid options: ($( IFS=$", "; echo "${options[*]}" ))"
	fi
}

function handle_xcodebuild_fail {
	if [[ "${output_tool}" == "xcpretty" ]] ; then
		cp $xcodebuild_output "$BITRISE_DEPLOY_DIR/raw-xcodebuild-output.log"
		echo_warn "If you can't find the reason of the error in the log, please check the raw-xcodebuild-output.log
The log file is stored in \$BITRISE_DEPLOY_DIR, and its full path
is available in the \$BITRISE_XCODE_RAW_RESULT_TEXT_PATH environment variable"
	fi

	exit 1
}

#=======================================
# Main
#=======================================

#
# Validate parameters
echo_info "test bundle builder config:"
echo_details "* output_tool: $output_tool"
echo_details "* workdir: $workdir"
echo_details "* output_dir: $output_dir"
echo_details "* project_path: $project_path"
echo_details "* scheme: $scheme"
echo_details "* configuration: $configuration"

validate_required_input "project_path" $project_path
validate_required_input "scheme" $scheme
validate_required_input "output_tool" $output_tool
validate_required_input "output_dir" $output_dir

options=("xcpretty"  "xcodebuild")
validate_required_input_with_options "output_tool" $output_tool "${options[@]}"

# Detect Xcode major version
xcode_major_version=""
major_version_regex="Xcode ([0-9]{1,2}).[0-9]"
out=$(xcodebuild -version)
if [[ "${out}" =~ ${major_version_regex} ]] ; then
	xcode_major_version="${BASH_REMATCH[1]}"
fi

if [ "${xcode_major_version}" -lt "8" ] ; then
	echo_fail "Invalid xcode major version: ${xcode_major_version}, should be greater then 8"
fi

IFS=$'\n'
xcodebuild_version_split=($out)
unset IFS

echo_info "step determined configs:"
xcodebuild_version="${xcodebuild_version_split[0]} (${xcodebuild_version_split[1]})"
echo_details "* xcodebuild_version: $xcodebuild_version"

# Detect xcpretty version
xcpretty_version=""
if [[ "${output_tool}" == "xcpretty" ]] ; then
	set +e
	xcpretty_version=$(xcpretty --version)
	exit_code=$?
	set -e
	if [[ $exit_code != 0 || -z "$xcpretty_version" ]] ; then
		echo_fail "xcpretty is not installed
For xcpretty installation see: 'https://github.com/supermarin/xcpretty',
or use 'xcodebuild' as 'output_tool'.
"
	fi

	echo_details "* xcpretty_version: $xcpretty_version"
fi


# Project-or-Workspace flag
if [[ "${project_path}" == *".xcodeproj" ]]; then
	CONFIG_xcode_project_action="-project"
elif [[ "${project_path}" == *".xcworkspace" ]]; then
	CONFIG_xcode_project_action="-workspace"
else
	echo_fail "Failed to get valid project file (invalid project file): ${project_path}"
fi
echo_details "* CONFIG_xcode_project_action: $CONFIG_xcode_project_action"

echo

# abs out dir pth
mkdir -p "${output_dir}"
cd "${output_dir}"
output_dir="$(pwd)"
cd -

# output files
ipa_path="${output_dir}/${scheme}.ipa"
echo_details "* ipa_path: $ipa_path"

# work dir
if [ ! -z "${workdir}" ] ; then
	echo_info "Switching to working directory: ${workdir}"
	cd "${workdir}"
fi

#
# Main

#
# Bit of cleanup
if [ -f "${ipa_path}" ] ; then
	echo_warn "IPA at path (${ipa_path}) already exists - removing it"
	rm "${ipa_path}"
fi

#
# Create the Archive with Xcode Command Line tools
echo_info "Create the IPA ..."

archive_cmd="xcodebuild ${CONFIG_xcode_project_action} \"${project_path}\""
archive_cmd="$archive_cmd -scheme \"${scheme}\""

if [ ! -z "${configuration}" ] ; then
	archive_cmd="$archive_cmd -configuration \"${configuration}\""
fi

archive_cmd="$archive_cmd build-for-testing -derivedDataPath ./build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO"



xcodebuild_output=""
if [[ "${output_tool}" == "xcpretty" ]] ; then
	xcodebuild_output="$(mktemp -d)/raw-xcodebuild-output.log"
	archive_cmd="set -o pipefail && $archive_cmd | tee $xcodebuild_output | xcpretty"
	envman add --key BITRISE_XCODE_RAW_RESULT_TEXT_PATH --value $xcodebuild_output
fi

echo_details "$ $archive_cmd"
echo

set +e
eval $archive_cmd
exit_status=$?
set -e

if [ $exit_status != 0 ] ; then
	handle_xcodebuild_fail
fi






# create the Payload.ipa file
# we don't have the config name so using *, assuming that there will be only one
test_runner_path=$(find "build/Build/Products/"*"-iphoneos/${scheme}-Runner.app" -print -quit)
if [ $? != 0 ] ; then
  echo "out: $test_runner_path"
  exit 1
fi

payload_directory="Payload"
ipa_path=Payload.ipa
zip_path=Payload.zip

# create the payload directory
mkdir -p "$payload_directory"

if [ $? != 0 ] ; then
  echo "out: failed to create Payload folder"
  exit 1
fi

#copy the test runner in the payload directory
cp -R "$test_runner_path" "$payload_directory"

if [ $? != 0 ] ; then
  echo "out: failed to copy test runner"
  exit 1
fi

# zip the folder
# this command is important to get right so that archive only contains relative path
zip -r "$ipa_path" "$payload_directory"

if [ $? != 0 ] ; then
  echo "out: failed to zip payload"
  exit 1
fi




# ensure ipa_path exists
if [ ! -e "${ipa_path}" ] ; then
    echo_fail "no ipa generated at: ${ipa_path}"
fi

#
# Export *.ipa path
export TEST_BUNDLE_IPA_PATH="${ipa_path}"
envman add --key TEST_BUNDLE_IPA_PATH --value "${TEST_BUNDLE_IPA_PATH}"
echo_done 'The IPA path is now available in the Environment Variable: $TEST_BUNDLE_IPA_PATH'" (value: $TEST_BUNDLE_IPA_PATH)"


exit 0







#
# --- Export Environment Variables for other Steps:
# You can export Environment Variables for other Steps with
#  envman, which is automatically installed by `bitrise setup`.
# A very simple example:
#  envman add --key EXAMPLE_STEP_OUTPUT --value 'the value you want to share'
# Envman can handle piped inputs, which is useful if the text you want to
# share is complex and you don't want to deal with proper bash escaping:
#  cat file_with_complex_input | envman add --KEY EXAMPLE_STEP_OUTPUT
# You can find more usage examples on envman's GitHub page
#  at: https://github.com/bitrise-io/envman

#
# --- Exit codes:
# The exit code of your Step is very important. If you return
#  with a 0 exit code `bitrise` will register your Step as "successful".
# Any non zero exit code will be registered as "failed" by `bitrise`.
