# Cloud Maker — Запуск виртуальной машины на Linux-хосте (Fedora) с QEMU/KVM
## Реализованный функционал
*   **Обязательное задание:** Создание и запуск ВМ через CLI (`virsh`, `qemu`, `virt-install`);
*   **Фича 2:** Ручная (без приложения) конфигурация ВМ при запуске через `cloud-init`; 
---
## Инструкция по запуску

### 1. Предварительные требования
Убедитесь, что на хосте (Fedora) установлены пакеты:
```bash
sudo dnf install qemu-kvm libvirt virt-install
```
### 2. Создаем директорию для запуска вм
```bash
mkdir -p ~/cloud-maker && cd ~/cloud-maker
```
### 3. Создаем конфигурацию для cloud-init
Мета-данные
```bash
cat > meta-data <<'EOF'
instance-id: cloud-maker-vm-01
local-hostname: cloud-maker-vm
EOF
```

Данные пользователя
```bash
cat > user-data <<'EOF'
#cloud-config
users:
  - name: cloud-user
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    plain_text_passwd: 'Word123!'
    lock_passwd: false
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB... your-public-key-here
ssh_pwauth: true
package_update: true
packages:
  - htop
  - curl
EOF
```
### 4. Скачиваем базовый cloud-image Ubuntu (например, 24.04 LTS)
```bash
curl -LO https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```
### 5. Создаем overlay-диск, чтобы не портить базовый образ
```bash
qemu-img create -f qcow2 -b noble-server-cloudimg-amd64.img -F qcow2 vm-disk.qcow2
```
### 6. Запускаем виртуальную машину (важно: замените <имя-владельца> на имя владельца хоста)
```bash
virt-install --connect qemu:///system \
--name cloud-maker-vm \
--osinfo ubuntu24.04 \
--vcpus 2 \
--memory 4096 \
--disk path=/home/<имя-владельца>/cloud-maker/vm-disk.qcow2,format=qcow2 \
--network network=default,model=virtio \
--graphics vnc,listen=0.0.0.0,port=5900 \
--cloud-init user-data=/home/<имя-владельца>/cloud-maker/user-data,meta-data=/home/<имя-владельца>/cloud-maker/meta-data \
--import \
--noautoconsole \
--check path_in_use=off
```
### 7. Готово!
Теперь, например, можем узнать айпи ВМ и подключиться к ней с помощью ssh
```bash
sudo virsh net-dhcp-leases default
```

```bash
ssh cloud-user@<user-ip>
```
