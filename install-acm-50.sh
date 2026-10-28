#!/bin/bash
set -euo pipefail

########################################################################
# ACM 5.0 Hackathon Installer
# Installs ACM 5.0 with bundled MCE 5.0 from ART FBC catalogs, then
# MultiClusterObservability. Same shape as the logging 6.6/6.7 scripts.
#
# Security:
#   - No registry tokens, kubeadmin passwords, or cloud keys in this file
#   - Stage token only via --token, STAGE_REGISTRY_TOKEN, or silent prompt
#   - Token is never written to the log file
#   - Pull-secret temp files are mode 0600 and deleted on exit
#   - Cloud credentials are read from local aws/gcloud config only
#   - Requires an existing oc login (this script never stores cluster passwords)
#
# Compatible with: OCP 5.0
########################################################################

readonly SCRIPT_VERSION="1.1.0"
readonly SUPPORTED_OCP_VERSIONS="5.0"

readonly ACM_CATALOG_PINNED="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc@sha256:31ad04c6ed1022944edec50584728b8d03d2828d170d685f79bbf454c307174e"
readonly MCE_CATALOG_PINNED="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc@sha256:8738712e8b525dd7351d72144d684b81f2f64fed38f4e3480a25b052a183c487"
readonly ACM_CATALOG_TAG="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:acm-5.0__v5.0__multiclusterhub-rhel9"
readonly MCE_CATALOG_TAG="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:mce-5.0__v5.0__backplane-rhel9-operator"

readonly ACM_NS="open-cluster-management"
readonly MCE_NS="multicluster-engine"
readonly OBS_NS="open-cluster-management-observability"
readonly ACM_CATALOG_NAME="acm-art"
readonly MCE_CATALOG_NAME="mce-art"
readonly IDMS_NAME="acm-stage"

STAGE_REGISTRY_TOKEN="${STAGE_REGISTRY_TOKEN:-}"
EMAIL=""
DRY_RUN=false
UNINSTALL=false
USE_LATEST=false
SKIP_OBSERVABILITY=false
DELETE_BUCKET=false
MCP_TIMEOUT=30
MCH_TIMEOUT=30
MCO_TIMEOUT=30
LOG_FILE=""
ACM_CHANNEL=""
MCE_CHANNEL=""
ACM_CATALOG_IMAGE=""
MCE_CATALOG_IMAGE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

_log() {
    # Visible output on stderr so $(...) never captures secrets or status lines.
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo -e "$1" | tee -a "$LOG_FILE" >&2
    else
        echo -e "$1" >&2
    fi
}

info()    { _log "${BLUE}[INFO]${NC} $*"; }
success() { _log "${GREEN}[OK]${NC}   $*"; }
warn()    { _log "${YELLOW}[WARN]${NC} $*"; }
error()   { _log "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { _log "\n${GREEN}━━━ Step $1: $2 ━━━${NC}"; }

usage() {
    cat <<EOF
ACM 5.0 Hackathon Installer v${SCRIPT_VERSION}

Installs ACM 5.0 + bundled MCE 5.0 from ART FBC catalogs on OCP 5.0,
then deploys MultiClusterObservability (AWS or GCP object storage).

Usage:
  $(basename "$0") [OPTIONS]

Options:
  --email EMAIL            Red Hat email prefix (e.g. pripatil)
  --token TOKEN            Base64-encoded stage registry token
                           (or set STAGE_REGISTRY_TOKEN). Never logged.
  --timeout MINUTES        Wait timeout for MCP, MultiClusterHub, and MCO (default: 30).
                           The script stays running until success or this timeout.
  --latest                 Use floating ACM/MCE FBC tags instead of Testathon pins
  --skip-observability     Install hub only; do not deploy MultiClusterObservability
  --dry-run                Show what would be done without executing
  --uninstall              Remove ACM/MCE/MCO/catalogs/acm-stage IDMS only
  --delete-bucket          With --uninstall, also delete the Thanos object-storage bucket
  -h, --help               Show this help

Credentials:
  Stage registry token is required only if the cluster pull-secret does not
  already contain registry.stage.redhat.io. Provide it via:
    1. --token flag
    2. STAGE_REGISTRY_TOKEN environment variable
    3. Silent interactive prompt
  This script never hardcodes or logs that token.
  Cluster login must already exist (oc login). Cloud keys come from
  ~/.aws/credentials or ~/.gcp/*.json and are not printed.

Examples:
  $(basename "$0") --email pripatil
  $(basename "$0") --email pripatil --skip-observability
  $(basename "$0") --email pripatil --latest --dry-run
  $(basename "$0") --uninstall
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email)
                EMAIL="$2"; shift 2 ;;
            --token)
                STAGE_REGISTRY_TOKEN="$2"; shift 2 ;;
            --timeout)
                MCP_TIMEOUT="$2"
                MCH_TIMEOUT="$2"
                MCO_TIMEOUT="$2"
                shift 2 ;;
            --latest)
                USE_LATEST=true; shift ;;
            --skip-observability)
                SKIP_OBSERVABILITY=true; shift ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --uninstall)
                UNINSTALL=true; shift ;;
            --delete-bucket)
                DELETE_BUCKET=true; shift ;;
            -h|--help)
                usage ;;
            *)
                error "Unknown option: $1. Use --help for usage." ;;
        esac
    done
}

need_cmd() {
    command -v "$1" &>/dev/null || error "'$1' is required but not installed."
}

has_stage_auth() {
    local present
    present=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
        | base64 -d \
        | jq -r 'if .auths["registry.stage.redhat.io"].auth then "yes" else "no" end' 2>/dev/null || echo "no")
    [[ "$present" == "yes" ]]
}

wait_for_mcp() {
    local timeout_seconds=$((MCP_TIMEOUT * 60))
    info "Waiting for MachineConfigPools to update (timeout: ${MCP_TIMEOUT}m)..."
    local start_time
    start_time=$(date +%s)

    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout_seconds ]]; then
            error "MCP update timed out after ${MCP_TIMEOUT} minutes. Check: oc get mcp"
        fi

        local updating
        updating=$(oc get mcp -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Updating")].status}{" "}{end}' 2>/dev/null || true)
        if ! echo "$updating" | grep -q "True"; then
            local degraded
            degraded=$(oc get mcp -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Degraded")].status}{" "}{end}' 2>/dev/null || true)
            if echo "$degraded" | grep -q "True"; then
                error "MCP is Degraded. Check: oc get mcp"
            fi
            success "All MachineConfigPools updated"
            return 0
        fi
        printf "\r  Waiting... (%dm elapsed)  " $((elapsed / 60))
        sleep 20
    done
}

wait_for_condition() {
    local description="$1"
    local timeout_sec="$2"
    local interval="${3:-15}"
    shift 3
    local start_time elapsed
    start_time=$(date +%s)
    while true; do
        if "$@" &>/dev/null; then
            return 0
        fi
        elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout_sec ]]; then
            return 1
        fi
        printf "\r  Waiting for %s... (%ds elapsed)  " "$description" "$elapsed"
        sleep "$interval"
    done
}

preflight_checks() {
    step "0" "Pre-flight checks"

    need_cmd oc
    need_cmd jq
    need_cmd python3
    success "oc, jq, python3 found"

    if ! oc whoami &>/dev/null; then
        error "Not logged into an OpenShift cluster. Run 'oc login' first. This script does not store cluster passwords."
    fi
    local cluster_user cluster_server
    cluster_user=$(oc whoami)
    cluster_server=$(oc whoami --show-server)
    success "Logged in as: ${cluster_user} @ ${cluster_server}"

    if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
        error "cluster-admin (or equivalent) is required."
    fi
    success "cluster-admin check passed"

    local ocp_full ocp_version
    ocp_full=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
    ocp_version=$(echo "$ocp_full" | awk -F. '{print $1"."$2}')
    if [[ ! "$ocp_version" =~ ^($SUPPORTED_OCP_VERSIONS)$ ]]; then
        error "OCP version ${ocp_full:-unknown} is not supported. This installer targets OCP 5.0."
    fi
    success "OCP version: ${ocp_full} (supported)"

    if [[ "$UNINSTALL" == true ]]; then
        return 0
    fi

    local csv2
    csv2=$(oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -E '^advanced-cluster-management\.v2' | head -n 1 || true)
    if [[ -n "$csv2" ]]; then
        error "Found ACM 2.x CSV (${csv2}). Uninstall ACM 2.x before installing ACM 5. Use: $0 --uninstall  (only if this script installed it) or remove the 2.x operator first."
    fi
}

collect_credentials_if_needed() {
    step "0.5" "Stage registry credentials"

    if has_stage_auth; then
        success "Cluster pull-secret already contains registry.stage.redhat.io (skipping token prompt)"
        STAGE_REGISTRY_TOKEN=""
        return 0
    fi

    info "Pull-secret is missing registry.stage.redhat.io"
    if [[ -z "$STAGE_REGISTRY_TOKEN" ]]; then
        echo ""
        info "Paste a base64-encoded stage registry token (input is hidden, not logged)."
        info "Or rerun with --token / STAGE_REGISTRY_TOKEN."
        echo ""
        read -r -s -p "  Stage registry token: " STAGE_REGISTRY_TOKEN
        echo ""
    fi

    if [[ -z "$STAGE_REGISTRY_TOKEN" ]]; then
        error "Registry token cannot be empty when pull-secret has no stage auth."
    fi
    if ! echo "$STAGE_REGISTRY_TOKEN" | base64 -d &>/dev/null; then
        error "Token does not appear to be valid base64."
    fi
    success "Stage registry token accepted (not written to log)"
}

step_update_pull_secret() {
    step "1" "Pull-secret (registry.stage.redhat.io)"

    if has_stage_auth; then
        success "Pull-secret already has stage registry auth (skipping)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would add registry.stage.redhat.io to pull-secret"
        return 0
    fi

    if [[ -z "$EMAIL" ]]; then
        error "Email prefix is required to update pull-secret. Use --email."
    fi

    local tmp_current tmp_new
    tmp_current=$(mktemp /tmp/acm5-pull-current-XXXXXX.json)
    tmp_new=$(mktemp /tmp/acm5-pull-new-XXXXXX.json)
    chmod 600 "$tmp_current" "$tmp_new"

    oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$tmp_current"
    chmod 600 "$tmp_current"

    jq --arg token "$STAGE_REGISTRY_TOKEN" --arg email "${EMAIL}@redhat.com" \
        '.auths["registry.stage.redhat.io"] = {"auth": $token, "email": $email}' \
        "$tmp_current" > "$tmp_new"
    chmod 600 "$tmp_new"
    unset STAGE_REGISTRY_TOKEN

    if ! python3 -m json.tool "$tmp_new" >/dev/null; then
        rm -f "$tmp_current" "$tmp_new"
        error "Generated pull-secret JSON is invalid."
    fi

    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$tmp_new"
    rm -f "$tmp_current" "$tmp_new"
    success "Pull-secret updated with registry.stage.redhat.io"

    info "Waiting for MCP to pick up pull-secret change..."
    sleep 15
    wait_for_mcp
}

ensure_catalog_source() {
    local name="$1"
    local image="$2"
    local display="$3"

    if oc get catalogsource "$name" -n openshift-marketplace &>/dev/null; then
        local current_image
        current_image=$(oc get catalogsource "$name" -n openshift-marketplace -o jsonpath='{.spec.image}')
        if [[ "$current_image" == "$image" ]]; then
            success "CatalogSource ${name} already exists with the expected image"
            return 0
        fi
        warn "CatalogSource ${name} exists with a different image; recreating"
        if [[ "$DRY_RUN" == false ]]; then
            oc delete catalogsource "$name" -n openshift-marketplace --wait=true
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would create CatalogSource ${name}"
        return 0
    fi

    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${name}
  namespace: openshift-marketplace
spec:
  displayName: ${display}
  image: ${image}
  publisher: grpc
  sourceType: grpc
  priority: 100
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
    success "CatalogSource ${name} created"
}

step_create_catalog_sources() {
    step "2" "Creating CatalogSources"

    if [[ "$USE_LATEST" == true ]]; then
        ACM_CATALOG_IMAGE="$ACM_CATALOG_TAG"
        MCE_CATALOG_IMAGE="$MCE_CATALOG_TAG"
        info "Using floating FBC tags (--latest)"
    else
        ACM_CATALOG_IMAGE="$ACM_CATALOG_PINNED"
        MCE_CATALOG_IMAGE="$MCE_CATALOG_PINNED"
        info "Using Testathon-pinned FBC digests"
    fi

    ensure_catalog_source "$ACM_CATALOG_NAME" "$ACM_CATALOG_IMAGE" "acm-art"
    ensure_catalog_source "$MCE_CATALOG_NAME" "$MCE_CATALOG_IMAGE" "mce-art"
}

step_create_idms() {
    step "3" "Creating ImageDigestMirrorSet ${IDMS_NAME}"

    if oc get imagedigestmirrorset logging-stage &>/dev/null; then
        info "Leaving existing logging-stage IDMS untouched"
    fi

    if oc get imagedigestmirrorset "$IDMS_NAME" &>/dev/null; then
        success "ImageDigestMirrorSet ${IDMS_NAME} already exists (skipping)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would create ImageDigestMirrorSet ${IDMS_NAME}"
        return 0
    fi

    oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${IDMS_NAME}
spec:
  imageDigestMirrors:
    - mirrors:
        - registry.stage.redhat.io/rhacm2
      source: registry.redhat.io/rhacm2
    - mirrors:
        - registry.stage.redhat.io/multicluster-engine
      source: registry.redhat.io/multicluster-engine
    - mirrors:
        - registry.stage.redhat.io/openshift4/ose-aws-cluster-api-controllers-rhel9
      source: registry.redhat.io/openshift4/ose-aws-cluster-api-controllers-rhel9
    - mirrors:
        - registry.stage.redhat.io/openshift4/ose-cluster-api-rhel9
      source: registry.redhat.io/openshift4/ose-cluster-api-rhel9
    - mirrors:
        - registry.stage.redhat.io/openshift4/ose-baremetal-cluster-api-controllers-rhel9
      source: registry.redhat.io/openshift4/ose-baremetal-cluster-api-controllers-rhel9
    - mirrors:
        - registry.redhat.io/openshift4/ose-oauth-proxy
      source: registry.access.redhat.com/openshift4/ose-oauth-proxy
EOF
    success "ImageDigestMirrorSet ${IDMS_NAME} created"
    info "Waiting for MCP to apply mirror configuration..."
    sleep 15
    wait_for_mcp
}

step_validate_catalog_sources() {
    step "4" "Validating CatalogSources are READY"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would wait for CatalogSources to become READY"
        return 0
    fi

    local source state attempt retries=24 delay=15
    for source in "$ACM_CATALOG_NAME" "$MCE_CATALOG_NAME"; do
        info "Waiting for CatalogSource ${source}..."
        attempt=0
        while [[ $attempt -lt $retries ]]; do
            state=$(oc get catalogsource "$source" -n openshift-marketplace \
                -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
            if [[ "$state" == "READY" ]]; then
                success "CatalogSource ${source} is READY"
                break
            fi
            attempt=$((attempt + 1))
            if [[ $attempt -ge $retries ]]; then
                error "CatalogSource ${source} did not become READY. Check: oc get catalogsource ${source} -n openshift-marketplace -o yaml"
            fi
            sleep "$delay"
        done
    done
}

step_cleanup_stale_jobs() {
    step "5" "Cleaning failed ACM/MCE unpack jobs"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would delete failed acm-art/mce-art unpack jobs"
        return 0
    fi

    local job
    while read -r job; do
        [[ -z "$job" ]] && continue
        info "Deleting failed job ${job}"
        oc delete job "$job" -n openshift-marketplace --ignore-not-found >/dev/null
    done < <(oc get jobs -n openshift-marketplace -o json 2>/dev/null \
        | jq -r '.items[] | select((.status.failed // 0) > 0) | select(.metadata.name | test("acm-art|mce-art")) | .metadata.name' || true)
    success "Stale ACM/MCE unpack jobs cleaned (logging jobs left alone)"
}

pick_channel() {
    local package="$1"
    local catalog="$2"
    shift 2
    local preferred=("$@")
    local channels
    channels=$(oc get packagemanifest -n openshift-marketplace -o json \
        | jq -r --arg pkg "$package" --arg cat "$catalog" '
            .items[]
            | select(.metadata.name == $pkg and .status.catalogSource == $cat)
            | .status.channels[].name' 2>/dev/null || true)

    if [[ -z "$channels" ]]; then
        error "Package ${package} not found in catalog ${catalog}. Catalog may not be READY or is the wrong FBC."
    fi

    local want
    for want in "${preferred[@]}"; do
        if echo "$channels" | grep -qx "$want"; then
            echo "$want"
            return 0
        fi
    done

    error "No ACM 5 channel in ${catalog} for ${package}. Found: $(echo "$channels" | tr '\n' ' '). Aborting so we do not install 2.17 from redhat-operators."
}

step_detect_channels() {
    step "6" "Detecting ACM 5 / MCE 5 channels"

    if [[ "$DRY_RUN" == true ]]; then
        ACM_CHANNEL="release-5.0"
        MCE_CHANNEL="stable-5.0"
        info "[DRY-RUN] Would detect channels (assuming ACM ${ACM_CHANNEL}, MCE ${MCE_CHANNEL})"
        return 0
    fi

    ACM_CHANNEL=$(pick_channel "advanced-cluster-management" "$ACM_CATALOG_NAME" "release-5.0" "stable-5.0")
    MCE_CHANNEL=$(pick_channel "multicluster-engine" "$MCE_CATALOG_NAME" "stable-5.0" "release-5.0")
    success "ACM channel: ${ACM_CHANNEL} (catalog ${ACM_CATALOG_NAME})"
    success "MCE channel: ${MCE_CHANNEL} (catalog ${MCE_CATALOG_NAME})"
}

step_install_acm_operator() {
    step "7" "Installing ACM operator from ${ACM_CATALOG_NAME}"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would create namespace/OperatorGroup/Subscription in ${ACM_NS}"
        return 0
    fi

    oc create namespace "$ACM_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null

    if ! oc get operatorgroup acm-operatorgroup -n "$ACM_NS" &>/dev/null; then
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: acm-operatorgroup
  namespace: ${ACM_NS}
spec:
  targetNamespaces:
    - ${ACM_NS}
EOF
        success "OperatorGroup acm-operatorgroup created"
    else
        success "OperatorGroup acm-operatorgroup already exists"
    fi

    if oc get sub advanced-cluster-management -n "$ACM_NS" &>/dev/null; then
        local src ch
        src=$(oc get sub advanced-cluster-management -n "$ACM_NS" -o jsonpath='{.spec.source}')
        ch=$(oc get sub advanced-cluster-management -n "$ACM_NS" -o jsonpath='{.spec.channel}')
        if [[ "$src" != "$ACM_CATALOG_NAME" || "$ch" != "$ACM_CHANNEL" ]]; then
            warn "Patching ACM Subscription source=${ACM_CATALOG_NAME} channel=${ACM_CHANNEL} (was source=${src} channel=${ch})"
            oc patch sub advanced-cluster-management -n "$ACM_NS" --type merge \
                -p "{\"spec\":{\"source\":\"${ACM_CATALOG_NAME}\",\"sourceNamespace\":\"openshift-marketplace\",\"channel\":\"${ACM_CHANNEL}\"}}"
        else
            success "ACM Subscription already points at ${ACM_CATALOG_NAME}/${ACM_CHANNEL}"
        fi
    else
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: ${ACM_NS}
spec:
  channel: ${ACM_CHANNEL}
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: ${ACM_CATALOG_NAME}
  sourceNamespace: openshift-marketplace
EOF
        success "ACM Subscription created"
    fi
}

csv_phase() {
    local ns="$1"
    local prefix="$2"
    oc get csv -n "$ns" -o json 2>/dev/null \
        | jq -r --arg p "$prefix" '.items[] | select(.metadata.name | startswith($p)) | .status.phase' \
        | head -n 1
}

wait_for_csv_prefix() {
    local ns="$1"
    local prefix="$2"
    local timeout_sec="$3"
    local start_time elapsed phase
    start_time=$(date +%s)
    info "Waiting for CSV ${prefix}* in ${ns} (timeout $((timeout_sec / 60))m). Script stays running."
    while true; do
        phase=$(csv_phase "$ns" "$prefix")
        if [[ "$phase" == "Succeeded" ]]; then
            echo ""
            success "CSV ${prefix}* is Succeeded"
            return 0
        fi
        if [[ "$phase" == "Failed" ]]; then
            error "CSV ${prefix}* Failed. Check: oc get csv -n ${ns}"
        fi
        elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout_sec ]]; then
            error "Timed out waiting for CSV ${prefix}* in ${ns} (last phase: ${phase:-none})"
        fi
        printf "\r  Phase: %-16s (%ds elapsed, still installing)  " "${phase:-Pending}" "$elapsed"
        if (( elapsed > 0 && elapsed % 60 < 16 )); then
            info "Still waiting for CSV ${prefix}* (phase=${phase:-Pending}, ${elapsed}s elapsed)"
        fi
        sleep 15
    done
}

step_wait_acm_operator() {
    step "8" "Waiting for ACM 5.0 operator"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would wait for advanced-cluster-management.v5 CSV and webhook"
        return 0
    fi

    wait_for_csv_prefix "$ACM_NS" "advanced-cluster-management.v5" 900

    info "Waiting for multiclusterhub-operator-webhook endpoints..."
    if ! wait_for_condition "MCH webhook" 300 10 \
        oc get endpoints -n "$ACM_NS" multiclusterhub-operator-webhook -o jsonpath='{.subsets[0].addresses[0].ip}'; then
        error "MCH validating webhook has no endpoints. Check: oc get pods -n ${ACM_NS}"
    fi
    echo ""
    success "MCH webhook is ready"
}

mce_sub_spec_json() {
    printf '{"source":"%s","sourceNamespace":"openshift-marketplace","channel":"%s"}' \
        "$MCE_CATALOG_NAME" "$MCE_CHANNEL"
}

step_create_mch() {
    step "9" "Creating MultiClusterHub (bundled MCE from ${MCE_CATALOG_NAME})"

    local annotation
    annotation=$(mce_sub_spec_json)

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would create MultiClusterHub with mce-subscription-spec=${annotation}"
        return 0
    fi

    if oc get mch multiclusterhub -n "$ACM_NS" &>/dev/null; then
        info "MultiClusterHub already exists; ensuring MCE subscription annotation"
        oc annotate mch multiclusterhub -n "$ACM_NS" \
            "installer.open-cluster-management.io/mce-subscription-spec=${annotation}" \
            --overwrite
    else
        local attempt
        for attempt in $(seq 1 40); do
            if oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ${ACM_NS}
  annotations:
    installer.open-cluster-management.io/mce-subscription-spec: '${annotation}'
spec:
  localClusterName: local-cluster
EOF
            then
                success "MultiClusterHub created"
                break
            fi
            warn "MCH apply failed (attempt ${attempt}/40); retrying in 15s"
            sleep 15
            if [[ $attempt -eq 40 ]]; then
                error "Could not create MultiClusterHub after 40 attempts"
            fi
        done
    fi

    if oc get sub multicluster-engine -n "$MCE_NS" &>/dev/null; then
        local mce_ch
        mce_ch=$(oc get sub multicluster-engine -n "$MCE_NS" -o jsonpath='{.spec.channel}' 2>/dev/null || true)
        if [[ "$mce_ch" != "$MCE_CHANNEL" ]]; then
            warn "MCE Subscription channel is ${mce_ch:-empty}; patching to ${MCE_CHANNEL}"
            oc patch sub multicluster-engine -n "$MCE_NS" --type merge \
                -p "{\"spec\":{\"channel\":\"${MCE_CHANNEL}\",\"source\":\"${MCE_CATALOG_NAME}\",\"sourceNamespace\":\"openshift-marketplace\"}}"
        fi
    fi
}

step_wait_hub() {
    step "10" "Waiting for MultiClusterHub Running and MCE 5.0"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would wait for MCH Running and MCE CSV 5.0"
        return 0
    fi

    local timeout_sec=$((MCH_TIMEOUT * 60))
    local start_time elapsed phase
    start_time=$(date +%s)
    info "Waiting for MultiClusterHub phase=Running (timeout ${MCH_TIMEOUT}m). Script stays running; this often takes 10–20 minutes."
    while true; do
        phase=$(oc get mch multiclusterhub -n "$ACM_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        if [[ "$phase" == "Running" ]]; then
            echo ""
            success "MultiClusterHub is Running"
            break
        fi
        elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout_sec ]]; then
            error "Timed out waiting for MultiClusterHub Running (last phase: ${phase}). Check: oc get mch -n ${ACM_NS}; oc get sub -n ${MCE_NS}"
        fi
        printf "\r  MCH phase: %-16s (%dm elapsed, still installing)  " "$phase" $((elapsed / 60))
        if (( elapsed > 0 && elapsed % 60 < 25 )); then
            info "Still waiting for MultiClusterHub Running (phase=${phase}, ${elapsed}s elapsed)"
        fi
        sleep 20
    done

    info "Waiting for local-cluster to become Available..."
    local mc_start mc_elapsed avail
    mc_start=$(date +%s)
    while true; do
        avail=$(oc get managedcluster local-cluster -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || true)
        if [[ "$avail" == "True" ]]; then
            success "ManagedCluster local-cluster is Available"
            break
        fi
        mc_elapsed=$(( $(date +%s) - mc_start ))
        if [[ $mc_elapsed -ge 600 ]]; then
            warn "local-cluster not Available after 10m (hub is Running; import may still finish). Check: oc get managedcluster"
            break
        fi
        printf "\r  local-cluster Available=%-6s (%ds)  " "${avail:-False}" "$mc_elapsed"
        sleep 15
    done
    echo ""

    wait_for_csv_prefix "$MCE_NS" "multicluster-engine.v5" 600

    local mce_csv
    mce_csv=$(oc get csv -n "$MCE_NS" -o json \
        | jq -r '.items[] | select(.metadata.name | startswith("multicluster-engine.v")) | .metadata.name' \
        | head -n 1)
    if [[ "$mce_csv" == *v2.* ]]; then
        error "MCE CSV is ${mce_csv}, not 5.0. MCH likely used redhat-operators. Check the mce-subscription-spec annotation."
    fi
    success "MCE CSV: ${mce_csv}"
}

default_storageclass() {
    local sc
    sc=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
    if [[ -z "$sc" ]]; then
        sc="gp3-csi"
        warn "No default StorageClass annotated; using ${sc}"
    fi
    echo "$sc"
}

setup_cloud_for_observability() {
    PLATFORM=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || true)
    case "$PLATFORM" in
        AWS)
            need_cmd aws
            [[ -f "${HOME}/.aws/credentials" ]] || error "AWS credentials file ~/.aws/credentials not found."
            AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
            AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
            if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
                error "Could not read AWS keys via 'aws configure get' (values are not logged)."
            fi
            CLOUD_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null)
            CLOUD_REGION="${CLOUD_REGION:-us-west-2}"
            success "AWS observability backend (region ${CLOUD_REGION}; keys not logged)"
            ;;
        GCP)
            need_cmd gcloud
            GCP_CREDS_FILE="${HOME}/.gcp/osServiceAccount.json"
            if [[ ! -f "$GCP_CREDS_FILE" ]]; then
                GCP_CREDS_FILE=$(ls "${HOME}/.gcp/"*.json 2>/dev/null | head -n 1 || true)
            fi
            [[ -n "$GCP_CREDS_FILE" && -f "$GCP_CREDS_FILE" ]] || error "GCP service-account JSON not found in ~/.gcp/"
            gcloud auth activate-service-account --key-file="$GCP_CREDS_FILE" >/dev/null 2>&1 || true
            CLOUD_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.gcp.region}' 2>/dev/null)
            CLOUD_REGION="${CLOUD_REGION:-us-east1}"
            success "GCP observability backend (region ${CLOUD_REGION}; key file not printed)"
            ;;
        *)
            error "Observability object storage supports AWS and GCP. Detected platform: ${PLATFORM:-unknown}. Use --skip-observability."
            ;;
    esac
}

create_thanos_bucket() {
    local prefix="$1"
    local suffix bucket
    if command -v openssl &>/dev/null; then
        suffix=$(openssl rand -hex 4)
    else
        suffix=$(date +%s | tail -c 9)
    fi
    bucket="${prefix}${suffix}"
    case "$PLATFORM" in
        AWS)
            info "Creating S3 bucket ${bucket} in ${CLOUD_REGION}"
            if [[ "$CLOUD_REGION" == "us-east-1" ]]; then
                aws s3api create-bucket --bucket "$bucket" --region "$CLOUD_REGION" >/dev/null
            else
                aws s3api create-bucket --bucket "$bucket" --region "$CLOUD_REGION" \
                    --create-bucket-configuration LocationConstraint="$CLOUD_REGION" >/dev/null
            fi
            ;;
        GCP)
            info "Creating GCS bucket ${bucket} in ${CLOUD_REGION}"
            gcloud storage buckets create "gs://${bucket}" --location="$CLOUD_REGION" >/dev/null
            ;;
    esac
    echo "$bucket"
}

apply_thanos_secret() {
    local bucket="$1"
    local tmp
    tmp=$(mktemp /tmp/acm5-thanos-XXXXXX.yaml)
    chmod 600 "$tmp"

    case "$PLATFORM" in
        AWS)
            cat > "$tmp" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: ${OBS_NS}
type: Opaque
stringData:
  thanos.yaml: |
    type: s3
    config:
      bucket: ${bucket}
      endpoint: s3.${CLOUD_REGION}.amazonaws.com
      insecure: false
      access_key: ${AWS_ACCESS_KEY_ID}
      secret_key: ${AWS_SECRET_ACCESS_KEY}
EOF
            ;;
        GCP)
            python3 - "$tmp" "$GCP_CREDS_FILE" "$bucket" "$OBS_NS" <<'PY'
import json, sys
out, keyfile, bucket, ns = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sa = json.load(open(keyfile))
sa_block = json.dumps(sa, indent=2)
indented = "\n".join(("      " + line) if line else "" for line in sa_block.splitlines())
open(out, "w").write(f"""apiVersion: v1
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: {ns}
type: Opaque
stringData:
  thanos.yaml: |
    type: GCS
    config:
      bucket: {bucket}
      service_account: |-
{indented}
""")
PY
            chmod 600 "$tmp"
            ;;
    esac

    oc apply -f "$tmp" >/dev/null
    rm -f "$tmp"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY || true
}

step_install_observability() {
    step "11" "Installing MultiClusterObservability"

    if [[ "$SKIP_OBSERVABILITY" == true ]]; then
        info "Skipping observability (--skip-observability)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would create Thanos secret and MultiClusterObservability"
        return 0
    fi

    if oc get mco observability &>/dev/null; then
        success "MultiClusterObservability already exists (skipping)"
        return 0
    fi

    setup_cloud_for_observability
    oc create namespace "$OBS_NS" --dry-run=client -o yaml | oc apply -f - >/dev/null

    local bucket=""
    if oc get secret thanos-object-storage -n "$OBS_NS" &>/dev/null; then
        success "thanos-object-storage secret already exists (reusing; not printing contents)"
    else
        local key
        key=$(echo "${EMAIL:-acm5}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | head -c 12)
        [[ -n "$key" ]] || key="acm5"
        bucket=$(create_thanos_bucket "acm-observe-${key}-")
        apply_thanos_secret "$bucket"
        success "Created thanos-object-storage for bucket ${bucket}"
    fi

    local sc
    sc=$(default_storageclass)
    oc apply -f - <<EOF
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
spec:
  observabilityAddonSpec: {}
  storageConfig:
    storageClass: ${sc}
    metricObjectStorage:
      name: thanos-object-storage
      key: thanos.yaml
EOF
    success "MultiClusterObservability created (StorageClass ${sc})"

    local timeout_sec=$((MCO_TIMEOUT * 60)) start_time elapsed ready
    start_time=$(date +%s)
    info "Waiting for MultiClusterObservability Ready (timeout ${MCO_TIMEOUT}m). Script stays running."
    while true; do
        ready=$(oc get mco observability -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [[ "$ready" == "True" ]]; then
            echo ""
            success "MultiClusterObservability is Ready"
            return 0
        fi
        elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout_sec ]]; then
            error "MultiClusterObservability not Ready after ${MCO_TIMEOUT}m. Check: oc get mco observability; oc get pods -n ${OBS_NS}"
        fi
        printf "\r  Ready=%-6s (%dm elapsed, still installing)  " "${ready:-False}" $((elapsed / 60))
        if (( elapsed > 0 && elapsed % 60 < 25 )); then
            info "Still waiting for MultiClusterObservability Ready (${elapsed}s elapsed)"
        fi
        sleep 20
    done
}

step_final_validation() {
    step "12" "Installation summary"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would print ACM/MCE/MCH/MCO status"
        info "Log file: ${LOG_FILE}"
        return 0
    fi

    echo ""
    info "=== ACM 5.0 hub ==="
    oc get mch -n "$ACM_NS" 2>/dev/null || true
    echo ""
    info "=== CSVs ==="
    oc get csv -n "$ACM_NS" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null \
        | grep -E 'NAME|advanced-cluster-management' || true
    oc get csv -n "$MCE_NS" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null \
        | grep -E 'NAME|multicluster-engine' || true
    echo ""
    info "=== CatalogSources ==="
    oc get catalogsource -n openshift-marketplace "$ACM_CATALOG_NAME" "$MCE_CATALOG_NAME" \
        -o custom-columns=NAME:.metadata.name,STATE:.status.connectionState.lastObservedState,IMAGE:.spec.image 2>/dev/null || true
    echo ""
    info "=== ManagedCluster ==="
    oc get managedcluster 2>/dev/null || true
    echo ""
    if [[ "$SKIP_OBSERVABILITY" != true ]]; then
        info "=== MultiClusterObservability ==="
        oc get mco 2>/dev/null || true
        echo ""
    fi
    info "Log file: ${LOG_FILE}"
    echo ""
    success "Hub install steps finished. File bugs with Affects Version ACM 5.0 and label acm-testathon."
}

wait_deleted() {
    local kind="$1"
    local name="$2"
    local ns="${3:-}"
    local timeout="${4:-600}"
    local start_time elapsed
    start_time=$(date +%s)
    while true; do
        if [[ -n "$ns" ]]; then
            oc get "$kind" "$name" -n "$ns" &>/dev/null || return 0
        else
            oc get "$kind" "$name" &>/dev/null || return 0
        fi
        elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout ]]; then
            warn "Timed out waiting for ${kind}/${name} to delete"
            return 0
        fi
        sleep 10
    done
}

wait_ns_gone() {
    local ns="$1"
    local timeout="${2:-600}"
    oc get ns "$ns" &>/dev/null || return 0
    info "Waiting for namespace ${ns} to terminate..."
    if oc wait ns "$ns" --for=delete --timeout="${timeout}s" &>/dev/null; then
        success "Namespace ${ns} deleted"
        return 0
    fi
    warn "Namespace ${ns} still terminating after ${timeout}s"
}

delete_acm_crds() {
    info "Deleting leftover ACM/MCE CRDs (not Logging/Loki/COO)"
    local crd group
    while read -r crd; do
        [[ -z "$crd" ]] && continue
        group=${crd#*.}
        case "$group" in
            *open-cluster-management.io|hive.openshift.io|hiveinternal.openshift.io|agent-install.openshift.io|extensions.hive.openshift.io|multicluster.openshift.io|hypershift.openshift.io)
                info "  deleting CRD ${crd}"
                oc delete crd "$crd" --ignore-not-found --wait=false || true
                ;;
        esac
    done < <(oc get crd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
}

do_uninstall() {
    step "1" "Uninstalling ACM 5 (script stays running until teardown finishes)"
    warn "Logging, Loki, COO, clo-stage, lo-stage, and logging-stage IDMS will NOT be removed."
    warn "Cluster pull-secret will NOT be reverted."

    if oc get mco observability &>/dev/null; then
        info "Deleting MultiClusterObservability (can take several minutes)"
        oc delete mco observability --ignore-not-found --wait=false || true
        wait_deleted mco observability "" 900
    fi

    if oc get mch multiclusterhub -n "$ACM_NS" &>/dev/null; then
        info "Deleting MultiClusterHub (often 5–15 minutes). Script stays running."
        oc delete mch multiclusterhub -n "$ACM_NS" --ignore-not-found --wait=false || true
        wait_deleted mch multiclusterhub "$ACM_NS" 1200
    fi

    if oc get mce --no-headers 2>/dev/null | grep -q .; then
        info "Deleting MultiClusterEngine"
        oc delete mce --all --ignore-not-found --wait=false || true
        local mce_name
        mce_name=$(oc get mce -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [[ -n "$mce_name" ]]; then
            wait_deleted mce "$mce_name" "" 900
        fi
    fi

    info "Deleting ACM/MCE subscriptions and CSVs"
    oc delete sub advanced-cluster-management -n "$ACM_NS" --ignore-not-found || true
    oc delete sub multicluster-engine -n "$MCE_NS" --ignore-not-found || true
    oc get csv -n "$ACM_NS" -o name 2>/dev/null | grep advanced-cluster-management | xargs -r oc delete -n "$ACM_NS" --ignore-not-found || true
    oc get csv -n "$MCE_NS" -o name 2>/dev/null | grep multicluster-engine | xargs -r oc delete -n "$MCE_NS" --ignore-not-found || true

    info "Deleting OperatorGroups"
    oc delete operatorgroup --all -n "$ACM_NS" --ignore-not-found || true
    oc delete operatorgroup --all -n "$MCE_NS" --ignore-not-found || true

    info "Deleting ACM/MCE namespaces (not openshift-logging)"
    local ns
    for ns in "$OBS_NS" "$ACM_NS" "$MCE_NS" \
              open-cluster-management-hub \
              open-cluster-management-agent \
              open-cluster-management-agent-addon \
              local-cluster hive; do
        oc delete ns "$ns" --ignore-not-found --wait=false || true
    done
    for ns in "$OBS_NS" "$ACM_NS" "$MCE_NS" \
              open-cluster-management-hub \
              open-cluster-management-agent \
              open-cluster-management-agent-addon \
              local-cluster hive; do
        wait_ns_gone "$ns" 600
    done

    delete_acm_crds

    info "Deleting ACM/MCE CatalogSources only (not clo-stage/lo-stage)"
    oc delete catalogsource "$ACM_CATALOG_NAME" -n openshift-marketplace --ignore-not-found || true
    oc delete catalogsource "$MCE_CATALOG_NAME" -n openshift-marketplace --ignore-not-found || true

    info "Deleting IDMS ${IDMS_NAME} (not logging-stage)"
    oc delete imagedigestmirrorset "$IDMS_NAME" --ignore-not-found || true

    if [[ "$DELETE_BUCKET" == true ]]; then
        warn "--delete-bucket requested, but bucket name is not stored in this script. Delete the acm-observe-* bucket from the cloud console if needed."
    fi

    echo ""
    info "=== Post-uninstall check ==="
    oc get mch -A 2>/dev/null || true
    oc get mce -A 2>/dev/null || true
    oc get mco 2>/dev/null || true
    oc get ns | grep -E 'open-cluster-management|multicluster-engine' || info "No ACM/MCE namespaces remain"
    echo ""
    success "Uninstall finished. Pull-secret, Logging, Loki, and COO were left in place."
}

main() {
    parse_args "$@"

    LOG_FILE="/tmp/acm5-hackathon-install-$(date +%Y%m%d-%H%M%S).log"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║     ACM 5.0 Hackathon Installer v${SCRIPT_VERSION}             ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [[ "$UNINSTALL" == true ]]; then
        preflight_checks
        do_uninstall
        exit 0
    fi

    if [[ -z "$EMAIL" ]]; then
        read -r -p "Enter your Red Hat email prefix (e.g. pripatil): " EMAIL
        if [[ -z "$EMAIL" ]]; then
            error "Email is required. Use --email."
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        warn "DRY-RUN mode: no changes will be made"
    fi

    info "Email: ${EMAIL}@redhat.com"
    info "MCP timeout: ${MCP_TIMEOUT} minutes"
    info "Latest FBC tags: ${USE_LATEST}"
    info "Observability: $([[ "$SKIP_OBSERVABILITY" == true ]] && echo skipped || echo enabled)"
    info "Log file: ${LOG_FILE}"
    echo ""

    preflight_checks
    collect_credentials_if_needed
    step_update_pull_secret
    step_create_catalog_sources
    step_create_idms
    step_validate_catalog_sources
    step_cleanup_stale_jobs
    step_detect_channels
    step_install_acm_operator
    step_wait_acm_operator
    step_create_mch
    step_wait_hub
    step_install_observability
    step_final_validation
}

main "$@"
