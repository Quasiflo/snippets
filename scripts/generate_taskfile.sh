#!/usr/bin/env bash
# Generates taskfile/taskfile.yml from taskfile/taskfile-template.yml plus
# taskfile/scripts/*.sh. Manual tasks live in the template; each script
# becomes one internal task named gen:<filename> (body embedded verbatim,
# shebang stripped) under singular `cmd:`, inserted at the
# __GENERATED_TASKS__ placeholder. This keeps a single Taskfile so remote
# consumers only ever do one level of import.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/taskfile/scripts"
TEMPLATE_FILE="${REPO_ROOT}/taskfile/taskfile-template.yml"
OUTPUT_FILE="${REPO_ROOT}/taskfile/taskfile.yml"
PLACEHOLDER='# __GENERATED_TASKS__'

CHECK_MODE=false

usage() {
	echo "Usage: $(basename "$0") [--check]" >&2
	echo "  (no args)  regenerate ${OUTPUT_FILE#"$REPO_ROOT"/}" >&2
	echo "  --check    exit 1 if generated file is stale (no write)" >&2
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--check)
		CHECK_MODE=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "Unknown argument: $1" >&2
		usage
		exit 1
		;;
	esac
done

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

placeholder_count="$(grep -c -F -x "${PLACEHOLDER}" "${TEMPLATE_FILE}" || true)"
if [[ ${placeholder_count} -ne 1 ]]; then
	echo "error: ${TEMPLATE_FILE#"$REPO_ROOT"/} must contain exactly one '${PLACEHOLDER}' line (found ${placeholder_count})" >&2
	exit 1
fi

script_files=()
while IFS= read -r entry; do
	[[ -n ${entry} ]] && script_files+=("${entry}")
done < <(find "${SOURCE_DIR}" -maxdepth 1 -name '*.sh' -type f | LC_ALL=C sort || true)

for src in "${script_files[@]}"; do
	name="$(basename "${src}")"
	first_line="$(head -n 1 "${src}")"
	if ! [[ ${first_line} =~ ^#!.*bash ]]; then
		echo "error: ${src}: missing bash shebang (expected #!/usr/bin/env bash)" >&2
		exit 1
	fi
	body="$(tail -n +2 "${src}")"
	if [[ -z ${body//[[:space:]]/} ]]; then
		echo "error: ${src}: empty after stripping shebang" >&2
		exit 1
	fi
done

while IFS= read -r line || [[ -n ${line} ]]; do
	if [[ ${line} == "${PLACEHOLDER}" ]]; then
		for src in "${script_files[@]}"; do
			name="$(basename "${src}")"
			{
				printf -- '  gen:%s:\n' "${name}"
				printf -- '    internal: true\n'
				printf -- '    silent: true\n'
				printf -- '    cmd: |\n'
				awk '{ if ($0 == "") { print "" } else { printf "      %s\n", $0 } }' "${src}" | tail -n +2
			} >>"${tmp_file}"
		done
	else
		printf -- '%s\n' "${line}" >>"${tmp_file}"
	fi
done <"${TEMPLATE_FILE}"

# Ensure single trailing newline.
tail -c1 "${tmp_file}" | read -r _ || printf -- '\n' >>"${tmp_file}"

if [[ ${CHECK_MODE} == true ]]; then
	if [[ ! -f ${OUTPUT_FILE} ]]; then
		echo "error: ${OUTPUT_FILE#"$REPO_ROOT"/} does not exist (run without --check to generate)" >&2
		exit 1
	fi
	if ! diff -u "${OUTPUT_FILE}" "${tmp_file}"; then
		echo "error: ${OUTPUT_FILE#"$REPO_ROOT"/} is stale (run scripts/generate_taskfile.sh to regenerate)" >&2
		exit 1
	fi
	echo "taskfile.yml is up to date"
else
	mkdir -p "$(dirname "${OUTPUT_FILE}")"
	mv "${tmp_file}" "${OUTPUT_FILE}"
	chmod 644 "${OUTPUT_FILE}"
	trap - EXIT
	echo "generated ${OUTPUT_FILE#"$REPO_ROOT"/}"
fi
