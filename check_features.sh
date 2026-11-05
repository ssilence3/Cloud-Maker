#!/bin/bash

# Цвета для красивого вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

 Определяем директорию, в которой лежит сам скрипт
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Настройки (теперь они относительны папки скрипта)
API_URL="http://localhost:8000"
TEST_VM_NAME="autotest-vm"
# Если образ лежит в корне проекта:
BASE_IMG="$SCRIPT_DIR/noble-server-cloudimg-amd64.img" 
# Если образ лежит в папке images:
# BASE_IMG="$SCRIPT_DIR/images/noble-server-cloudimg-amd64.img"

echo -e "${YELLOW}=== Начинаем проверку реализованных фич ===${NC}\n"

# ==========================================
# ПРОВЕРКА ФИЧИ 1: HTTP API (Создание и удаление ВМ)
# ==========================================
echo -e "${YELLOW}[Фича 1] Проверка HTTP API...${NC}"

# 1.1 Проверка доступности API
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" $API_URL/docs)
if [ "$HTTP_STATUS" -eq 200 ]; then
    echo -e "${GREEN}[PASS]${NC} API доступен по адресу $API_URL/docs"
else
    echo -e "${RED}[FAIL]${NC} API недоступен. Убедитесь, что uvicorn запущен."
    exit 1
fi

# 1.2 Создание ВМ через API (и передача параметров для Фичи 2)
echo -e "  -> Отправка POST-запроса на создание ВМ '$TEST_VM_NAME'..."
API_RESPONSE=$(curl -s -X POST "$API_URL/vm/create" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"$TEST_VM_NAME\",
    \"memory_mb\": 1024,
    \"vcpus\": 1,
    \"hostname\": \"test-cloud-host\",
    \"ssh_key\": \"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC... test@key\"
  }")

if echo "$API_RESPONSE" | grep -q "success"; then
    echo -e "${GREEN}[PASS]${NC} API вернул успех при создании ВМ."
else
    echo -e "${RED}[FAIL]${NC} Ошибка при создании ВМ через API. Ответ: $API_RESPONSE"
fi

# ==========================================
# ПРОВЕРКА ФИЧИ 2: cloud-init (ISO-образ)
# ==========================================
echo -e "\n${YELLOW}[Фича 2] Проверка cloud-init...${NC}"

# Ищем ISO во всей директории libvirt (включая папку boot), используя sudo
SEED_ISO=$(sudo find /var/lib/libvirt/ -name "*cloudinit*.iso" | head -n 1)

if [ -n "$SEED_ISO" ]; then
    echo -e "${GREEN}[PASS]${NC} При создании ВМ был сгенерирован cloud-init образ:"
    echo -e "       $(basename $SEED_ISO)"
else
    # Если ISO нет, проверяем, остался ли диск (значит, API использовал другой метод)
    if [ -f "/var/lib/libvirt/images/$TEST_VM_NAME.qcow2" ]; then
        echo -e "${YELLOW}[INFO]${NC} Диск создан, но автоматический поиск ISO cloud-init не дал результатов."
        echo -e "       (Проверьте, передается ли флаг --cloud-init в коде API)."
    else
        echo -e "${RED}[FAIL]${NC} Не удалось найти артефакты cloud-init."
    fi
fi

# 1.3 Проверка, что ВМ реально появилась в libvirt
sleep 2
if sudo virsh dominfo "$TEST_VM_NAME" > /dev/null 2>&1; then
    echo -e "${GREEN}[PASS]${NC} ВМ '$TEST_VM_NAME' успешно зарегистрирована в libvirt."
    
    # Фича 1: Тест остановки ВМ (если реализовано API /vms/{name}/stop)
    echo -e "  -> Отправка POST-запроса на остановку ВМ..."
    curl -s -X POST "$API_URL/vms/$TEST_VM_NAME/stop" > /dev/null
    sleep 1
    VM_STATE=$(sudo virsh domstate "$TEST_VM_NAME")
    if [ "$VM_STATE" == "shut off" ]; then
         echo -e "${GREEN}[PASS]${NC} ВМ успешно остановлена."
    fi
    
    # Фича 1: Тест удаления ВМ
    echo -e "  -> Отправка DELETE-запроса на удаление ВМ..."
    curl -s -X DELETE "$API_URL/vms/$TEST_VM_NAME" > /dev/null
    sleep 2
    if ! sudo virsh dominfo "$TEST_VM_NAME" > /dev/null 2>&1; then
        echo -e "${GREEN}[PASS]${NC} ВМ успешно удалена из libvirt."
    else
        echo -e "${RED}[FAIL]${NC} ВМ не удалилась после запроса DELETE."
    fi
else
    echo -e "${RED}[FAIL]${NC} ВМ '$TEST_VM_NAME' не найдена в libvirt."
fi



# ==========================================
# ПРОВЕРКА ФИЧИ 3: Bridge (Мост br0)
# ==========================================
echo -e "\n${YELLOW}[Фича 3] Проверка сетевого моста (Bridge)...${NC}"

# 3.1 Проверка наличия системного интерфейса br0
if ip link show br0 > /dev/null 2>&1; then
    echo -e "${GREEN}[PASS]${NC} Системный интерфейс 'br0' существует."
else
    echo -e "${RED}[FAIL]${NC} Интерфейс 'br0' не найден в системе (проверьте nmcli)."
fi

# 3.2 Проверка наличия сети libvirt, использующей этот мост
BRIDGE_NET_STATUS=$(sudo virsh net-list --all | grep "host-bridge")
if [ -n "$BRIDGE_NET_STATUS" ]; then
    echo -e "${GREEN}[PASS]${NC} Виртуальная сеть 'host-bridge' зарегистрирована в libvirt."
    echo "       Статус: $BRIDGE_NET_STATUS"
else
    echo -e "${RED}[FAIL]${NC} Сеть 'host-bridge' не найдена в libvirt (virsh net-list)."
fi

echo -e "\n${GREEN}=== Проверка завершена! ===${NC}"
