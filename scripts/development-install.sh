#!/bin/sh
# This script is for development purposes only! - no need to upload it to s3

verify_prerequisites() {
  if ! command -v openssl &>/dev/null; then
    printf '%s\n' "openssl doesn't exist, please install openssl"
    exit 1
  fi

  if ! command -v kubectl &>/dev/null; then
    printf '%s\n' "kubectl doesn't exist, please install kubectl"
    exit 1
  fi
}

verify_prerequisites

# Sets up the environment for the admission controller webhook in the active cluster.
# check that user have kubectl installed and openssl
# generate TLS keys
generate_keys() {
  printf "🔑 Generating TLS keys...\n"

  chmod 0700 "${keydir}"
  cd "${keydir}"

  cat >server.conf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no
[req_distinguished_name]
CN = webhook-server.datree.svc
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = webhook-server.datree.svc
EOF

  # Generate the CA cert and private key that is valid for 5 years
  openssl req -nodes -new -x509 -days 1827 -keyout ca.key -out ca.crt -subj "/CN=Admission Controller Webhook Demo CA"
  # Generate the private key for the webhook server
  openssl genrsa -out webhook-server-tls.key 2048
  # Generate a Certificate Signing Request (CSR) for the private key, and sign it with the private key of the CA.
  openssl req -new -key webhook-server-tls.key -subj "/CN=webhook-server.datree.svc" -config server.conf |
    openssl x509 -req -CA ca.crt -CAkey ca.key -CAcreateserial -out webhook-server-tls.crt -extensions v3_req -extfile server.conf

  cd -
}

verify_datree_namespace() {
  local namespace_exists
  namespace_exists="$(kubectl get namespace/datree --ignore-not-found)"

  if ! [[ -n "${namespace_exists}" ]]; then
    # Create the `datree` namespace. This cannot be part of the YAML file as we first need to create the TLS secret,
    # which would fail otherwise.
    printf "\n🏠 Creating datree namespace...\n"
    kubectl create namespace datree
  fi

  # Label datree namespace to avoid deadlocks in self hosted webhooks
  #  https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#avoiding-deadlocks-in-self-hosted-webhooks
  kubectl label namespaces datree admission.datree/validate=skip

  # label kube-system namespace to avoid operating on the kube-system namespace
  # https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#avoiding-operating-on-the-kube-system-namespace
  kubectl label namespaces kube-system admission.datree/validate=skip
}

override_core_resources() {
  printf "\n🔗 Creating core resources...\n"
  imagePullPolicy="Always"
  image='datree\/webhook-staging:latest'
  replicasCount=2
  if [[ "${IS_MINIKUBE}" == "true" ]]; then
    echo "Overriding core resources for minikube..."
    imagePullPolicy="Never"
    image="webhook-server"
    replicasCount=1
  fi
  sed 's/${DATREE_TOKEN}/'"$datree_token"'/g' <"${basedir}/kube/core-resources.yaml" |
    sed -e 's/imagePullPolicy: Always/imagePullPolicy: '"$imagePullPolicy"'/g' |
    sed 's/image:.*/image: '"${image}"'/g' |
    sed 's/replicas:.*/replicas: '"$replicasCount"'/g' |
    kubectl apply -f -
}

override_webhook_resource() {
  printf "\n🔗 Creating validation webhook resource...\n"

  # Read the PEM-encoded CA certificate, base64 encode it, and replace the `${CA_PEM_B64}` placeholder in the YAML
  # template with it. Then, create the Kubernetes resources.
  ca_pem_b64="$(openssl base64 -A <"${keydir}/ca.crt")"
  sed -e 's@${CA_PEM_B64}@'"$ca_pem_b64"'@g' <"${basedir}/kube/validating-webhook-configuration.yaml" |
    kubectl apply -f -
}

override_webhook_secret_tls() {
  # Generate keys into a temporary directory.
  generate_keys

  printf "\n🔗 Creating webhook secret tls...\n"

  # Override the TLS secret for the generated keys.
  kubectl delete secrets webhook-server-tls -n datree --ignore-not-found

  kubectl -n datree create secret tls webhook-server-tls \
    --cert "${keydir}/webhook-server-tls.crt" \
    --key "${keydir}/webhook-server-tls.key"
}

are_you_sure() {
  read -p "Are you sure you want to run as anonymous user? (y/N) " -n 1 -r
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo true
  else
    echo false
  fi
}

verify_correct_token_regex() {
  if [[ $datree_token =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ||
    $datree_token =~ ^[0-9a-zA-Z]{22}$ ||
    $datree_token =~ ^[0-9a-zA-Z]{20}$ ]]; then
    echo true
  else
    echo false
  fi
}

verify_datree_namespace

set -eo pipefail

# Create Temporary directory for TLS keys
keydir="$(mktemp -d)"

basedir="$(pwd)"

# Override DATREE_TOKEN env
if [ -z "$DATREE_TOKEN" ]; then
  echo
  echo ==============================================================================
  echo ======================= Finish setting up the webhook ========================
  echo ==============================================================================

  token_set=false
  while [ "$token_set" = false ]; do
    echo "👉 Insert token (available at https://app.datree.io/settings/token-management)"
    echo "ℹ️  The token is used to connect the webhook with your workspace."
    read datree_token
    token_set=true

    if [ -z "$datree_token" ]; then
      is_sure=$(are_you_sure)
      echo
      if [ $is_sure = false ]; then
        token_set=false
      fi
    else
      is_valid_token=$(verify_correct_token_regex)
      if [ $is_valid_token = false ]; then
        echo "🚫 Invalid token format"
        token_set=false
      fi
    fi
  done
else
  datree_token=$DATREE_TOKEN
fi

override_webhook_secret_tls

override_core_resources

# Wait for deployment rollout
rolloutExitCode=0
(kubectl rollout status deployment webhook-server -n datree --timeout=180s) || rolloutExitCode=$?

if [ "$rolloutExitCode" != "0" ]; then
  printf "\n❌  datree webhook rollout failed, please try again. If this keeps happening please contact us: https://github.com/datreeio/admission-webhook-datree/issues\n"
else
  override_webhook_resource
  # Delete the key directory to prevent abuse (DO NOT USE THESE KEYS ANYWHERE ELSE).
  rm -rf "${keydir}"

  printf "\n🎉 DONE! The webhook server is now deployed and configured\n"
fi
