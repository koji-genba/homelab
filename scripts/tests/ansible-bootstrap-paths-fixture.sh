#!/bin/sh
set -eu

python3 <<'PY'
import pathlib

import yaml

base_tasks = yaml.safe_load(pathlib.Path(
    "files/infrastructure/ansible/apps/roles/base/tasks/main.yml"
).read_text())
docker_tasks = yaml.safe_load(pathlib.Path(
    "files/infrastructure/ansible/apps/roles/docker/tasks/main.yml"
).read_text())

directory_task = next(
    task for task in base_tasks
    if task.get("name") == "Ensure host configuration drop-in directories exist"
)
assert set(directory_task["loop"]) >= {
    "/etc/ssh/sshd_config.d",
    "/etc/sudoers.d",
    "/etc/systemd/journald.conf.d",
}

journald_index = next(
    index for index, task in enumerate(base_tasks)
    if task.get("name") == "Configure bounded journald retention"
)
directory_index = next(
    index for index, task in enumerate(base_tasks)
    if task.get("name") == "Ensure host configuration drop-in directories exist"
)
assert directory_index < journald_index

docker_directory_task = next(
    task for task in docker_tasks
    if task.get("name") == "Ensure Docker configuration directory exists"
)
assert docker_directory_task["ansible.builtin.file"]["path"] == "/etc/docker"

repository_tasks = [
    task for task in docker_tasks
    if task.get("name") == "Configure Docker's official repository"
]
assert len(repository_tasks) == 1
repository = repository_tasks[0]
assert "ansible.builtin.apt_repository" not in repository
deb822 = repository["ansible.builtin.deb822_repository"]
assert deb822["signed_by"] == "/etc/apt/keyrings/docker.asc"
assert "apt-key" not in str(docker_tasks)

python_debian_task = next(
    task for task in base_tasks
    if task.get("name") == "Install Debian bindings for deb822 repository management"
)
assert python_debian_task["ansible.builtin.apt"]["name"] == "python3-debian"
PY

echo "Ansible bootstrap path fixture: ok"
