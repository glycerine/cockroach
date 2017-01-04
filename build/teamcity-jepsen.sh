#!/usr/bin/env bash
set -euxo pipefail

## This script provisions a Jepsen controller and 5 nodes, and runs tests
## against them.

COCKROACH_PATH="${GOPATH}/src/github.com/cockroachdb/cockroach"
KEY_NAME="${KEY_NAME-google_compute_engine}"
LOG_DIR="${COCKROACH_PATH}/artifacts"
mkdir -p "${LOG_DIR}"

cd "${COCKROACH_PATH}/cloud/gce/jepsen"

# Generate ssh keys for the controller to talk to the workers.
rm -f controller.id_rsa controller.id_rsa.pub
ssh-keygen -f controller.id_rsa -N ''

function destroy {
  set +e
  echo "Collecting logs..."
  controller="$(terraform output controller-ip)"
  scp -o "StrictHostKeyChecking no" -ri "$HOME/.ssh/${KEY_NAME}" "ubuntu@${controller}:jepsen/cockroachdb/store/latest" "${LOG_DIR}"
  echo "Tearing down cluster..."
  terraform destroy --var=key_name="${KEY_NAME}" --force
}
trap destroy EXIT

# Spin up the cluster.
terraform apply --var=key_name="${KEY_NAME}"

controller="$(terraform output controller-ip)"

nemeses=(
    # big-skews disabled since they assume an eth0 interface.
    #"--nemesis big-skews"
    "--nemesis majority-ring"
    "--nemesis start-stop-2"
    "--nemesis start-kill-2"
    #"--nemesis majority-ring --nemesis2 big-skews"
    #"--nemesis big-skews --nemesis2 start-kill-2"
    "--nemesis majority-ring --nemesis2 start-kill-2"
    "--nemesis parts --nemesis2 start-kill-2"
)

tests=(
    "bank"
    "comments"
    "register"
    "monotonic"
    "sets"
    "sequential"
)

testcmd_base="cd jepsen/cockroachdb && ~/lein run test --tarball file:///home/ubuntu/cockroach.tgz --username ubuntu --ssh-private-key ~/.ssh/id_rsa --nodes-file ~/nodes --time-limit 180 --test-count 10 --os ubuntu"

for test in "${tests[@]}"; do
    for nemesis in "${nemeses[@]}"; do
        testcmd="${testcmd_base} --test ${test} ${nemesis}"
        echo "Testing with args --test ${test} ${nemesis}"
        # Run each test over an ssh connection.
        # If this begins to time out frequently, let's do this via nohup and poll.
        ssh -o "StrictHostKeyChecking no" -i "$HOME/.ssh/${KEY_NAME}" "ubuntu@${controller}" "${testcmd}" 2>&1 | tee "${LOG_DIR}/controller.log"
    done
done
