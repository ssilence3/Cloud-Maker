from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import libvirt
import subprocess
import os
import uuid
import tempfile

app = FastAPI(title="Cloud Maker VM API")

# Подключаемся к системному демону libvirt
try:
    conn = libvirt.open('qemu:///system')
    if conn is None:
        raise Exception("Не удалось подключиться к libvirt")
except Exception as e:
    print(f"Ошибка инициализации libvirt: {e}")

class VMCreateRequest(BaseModel):
    name: str
    memory_mb: int = 2048
    vcpus: int = 2
    hostname: str = "my-cloud-vm"
    ssh_key: str = "ssh-rsa AAAA..." # Сюда передаем публичный ключ

@app.get("/vms")
def list_vms():
    """Получить список всех ВМ и их статус"""
    vms = []
    for dom in conn.listAllDomains():
        vms.append({
            "name": dom.name(),
            "state": "running" if dom.isActive() else "shut off",
            "id": dom.ID() if dom.isActive() else -1
        })
    return {"vms": vms}

@app.post("/vm/create")
def create_vm(req: VMCreateRequest):
    # 1. Проверяем, нет ли уже такой ВМ
    try:
        conn.lookupByName(req.name)
        raise HTTPException(status_code=400, detail="ВМ с таким именем уже существует")
    except libvirt.libvirtError:
        pass # Это хорошо, ВМ не существует

    # 2. Генерируем временные файлы user-data и meta-data
    with tempfile.TemporaryDirectory() as tmpdir:
        user_data_path = os.path.join(tmpdir, "user-data")
        meta_data_path = os.path.join(tmpdir, "meta-data")
        

        # Читаем шаблоны из папки cloud-maker и заменяем переменные
        with open(os.path.expanduser("/home/silence3/cloud-maker/user-data"), "r") as f:
            ud_content = f.read().replace("{{ hostname }}", req.hostname).replace("{{ ssh_key }}", req.ssh_key)
        
        with open(os.path.expanduser("/home/silence3/cloud-maker/meta-data"), "r") as f:
            md_content = f.read().replace("{{ hostname }}", req.hostname).replace("{{ instance_id }}", str(uuid.uuid4()))

        with open(user_data_path, "w") as f:
            f.write(ud_content)
        with open(meta_data_path, "w") as f:
            f.write(md_content)

        # 3. Создаем диск
        disk_path = f"/var/lib/libvirt/images/{req.name}.qcow2"
        base_image = "/home/silence3/cloud-maker/noble-server-cloudimg-amd64.img"
        cmd_qemu = [
            "qemu-img", "create", 
            "-f", "qcow2", 
            "-b", base_image, 
            "-F", "qcow2", 
            disk_path, 
            "10G"
        ]
        try:
            subprocess.run(cmd_qemu, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            raise HTTPException(status_code=500, detail=f"Ошибка qemu-img: {e.stderr}")
        
        # 4. Формируем команду virt-install
        cmd = [
            "virt-install",
            "--connect", "qemu:///system",
            "--name", req.name,
            "--osinfo", "ubuntu24.04",
            "--vcpus", str(req.vcpus),
            "--memory", str(req.memory_mb),
            "--disk", f"path={disk_path},format=qcow2",
            "--network", "network=default,model=virtio",
            "--graphics", "vnc,listen=0.0.0.0,port=-1",
            "--cloud-init", f"user-data={user_data_path},meta-data={meta_data_path}",
            "--import",
            "--noautoconsole"
        ]

        # 5. Запускаем создание
        try:
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            return {"status": "success", "message": f"ВМ {req.name} создана с cloud-init"}
        except subprocess.CalledProcessError as e:
            raise HTTPException(status_code=500, detail=f"Ошибка virt-install: {e.stderr}")
            
@app.post("/vms/{name}/start")
def start_vm(name: str):
    """Запустить ВМ"""
    try:
        dom = conn.lookupByName(name)
        if dom.isActive():
            return {"status": "info", "message": "ВМ уже запущена"}
        dom.create()
        return {"status": "success", "message": f"ВМ {name} запущена"}
    except libvirt.libvirtError:
        raise HTTPException(status_code=404, detail="ВМ не найдена")

@app.post("/vms/{name}/stop")
def stop_vm(name: str):
    """Остановить ВМ"""
    try:
        dom = conn.lookupByName(name)
        if not dom.isActive():
            return {"status": "info", "message": "ВМ уже выключена"}
        dom.destroy() # Принудительное выключение
        return {"status": "success", "message": f"ВМ {name} остановлена"}
    except libvirt.libvirtError:
        raise HTTPException(status_code=404, detail="ВМ не найдена")

@app.delete("/vms/{name}")
def delete_vm(name: str):
    """Удалить ВМ и её диск"""
    try:
        dom = conn.lookupByName(name)
        
        # Получаем путь к диску перед удалением
        disk_path = None
        for disk in dom.XMLDesc().split("<disk"): 
            if "source file=" in disk:
                disk_path = disk.split("source file='")[1].split("'")[0]
                break

        # Удаляем конфигурацию
        if dom.isActive():
            dom.destroy()
        dom.undefine()
        
        # Удаляем файл диска
        if disk_path and os.path.exists(disk_path):
            os.remove(disk_path)
            
        return {"status": "success", "message": f"ВМ {name} и её диск удалены"}
    except libvirt.libvirtError:
        raise HTTPException(status_code=404, detail="ВМ не найдена")
