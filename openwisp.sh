

# --- Configurazione Iniziale ---
VMID="128" # ID di default per la VM
VMNAME="openwisp-vm"
VMRAM="4096" # MB di RAM (OpenWISP raccomanda 2GB+, usiamo 4GB per sicurezza)
VMCORES="2"  # Numero di core CPU (OpenWISP raccomanda 2+)
VM_DISK="20" # GB di spazio disco (OpenWISP raccomanda 50GB+, usiamo 20GB come minimo, potresti voler aumentare)
BRIDGE="vmbr0" # Bridge di rete di Proxmox
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.tar.gz" # Ultima LTS (24.04 Noble Numbat)
CLOUD_IMAGE_NAME="noble-server-cloudimg-amd64.tar.gz"
STORAGE_POOL="local-lvm" # Pool di storage dove creare il disco della VM
NETWORK_IP="192.168.1.128/24"
NETWORK_GW="192.168.1.1" # Sostituisci con il gateway corretto della tua rete
NETWORK_DNS="192.168.1.1" # Sostituisci con il DNS corretto della tua rete
VM_USER="ubuntu" # Utente di default per l'immagine cloud
SSH_PUB_KEY="" # Opzionale: inserisci qui la tua chiave pubblica SSH tra apici per accesso senza password

# Genera password casuali per il database
DB_ROOT_PASSWORD=$(openssl rand -base64 16)
DB_OPENWISP_PASSWORD=$(openssl rand -base64 16)
DB_NAME="openwisp"
DB_USER="openwisp"

# --- Funzioni di Helper ---

# Funzione per verificare l'esito dell'ultimo comando
check_command() {
    if [ $? -ne 0 ]; then
        echo "Errore: $1 fallito."
        exit 1
    fi
}

# Funzione per scaricare l'immagine cloud se non presente
download_cloud_image() {
    if [ ! -f "/var/lib/vz/template/iso/$CLOUD_IMAGE_NAME" ]; then
        echo "Immagine cloud $CLOUD_IMAGE_NAME non trovata. Scaricamento in corso..."
        mkdir -p /var/lib/vz/template/iso
        wget -q -O "/var/lib/vz/template/iso/$CLOUD_IMAGE_NAME" "$CLOUD_IMAGE_URL"
        check_command "Scarimento immagine cloud"
        echo "Scarimento completato."
    else
        echo "Immagine cloud $CLOUD_IMAGE_NAME già presente."
    fi
}

# Funzione per attendere che il guest agent sia pronto
wait_for_agent() {
    echo "In attesa che il Qemu Guest Agent sia pronto..."
    SECONDS=0
    while [ $SECONDS -lt 300 ]; do # Attendi al massimo 300 secondi (5 minuti)
        if qm agent list network $VMID &>/dev/null; then
            echo "Guest Agent pronto."
            return 0
        fi
        sleep 5
    done
    echo "Errore: Qemu Guest Agent non pronto dopo 300 secondi. Impossibile procedere con l'installazione."
    exit 1
}

# Funzione per eseguire comandi all'interno della VM tramite qm agent exec
execute_in_vm() {
    local cmd="$1"
    echo "Esecuzione comando nella VM ($VMID):"
    echo "$cmd"
    qm agent exec $VMID -- bash -c "$cmd"
    check_command "Esecuzione comando nella VM"
}

# --- Inizio Script ---

echo "Questo script creerà una VM Ubuntu per OpenWisp con IP statico ${NETWORK_IP}."

# Richiedi conferma o modifica dei parametri
read -p "Procedere con VM ID ${VMID}, Nome ${VMNAME}, RAM ${VMRAM}MB, CPU ${VMCORES}, Disco ${VM_DISK}GB, Bridge ${BRIDGE}, Storage ${STORAGE_POOL}? (s/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    echo "Operazione annullata."
    exit 1
fi

# Verifica se la VM esiste già
if qm status $VMID &>/dev/null; then
    echo "Errore: Una VM con ID ${VMID} esiste già."
    exit 1
fi

# Scarica l'immagine cloud
download_cloud_image

# Crea la VM
echo "Creazione della VM ${VMNAME} (ID ${VMID})..."
qm create $VMID --name $VMNAME --memory $VMRAM --cores $VMCORES --net0 virtio,bridge=$BRIDGE
check_command "Creazione VM"

# Importa il disco dalla immagine cloud
echo "Importazione disco dalla immagine cloud..."
qm set $VMID --ide0 $STORAGE_POOL:vm-${VMID}-disk-0,format=qcow2,size=${VM_DISK}G
qm importdisk $VMID "/var/lib/vz/template/iso/$CLOUD_IMAGE_NAME" $STORAGE_POOL
check_command "Importazione disco"

# Allega il disco importato e configura boot
echo "Configurazione boot e allegato disco..."
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE_POOL:vm-${VMID}-disk-0
qm set $VMID --boot c --bootdisk scsi0
check_command "Configurazione boot"

# Configura Cloud-Init
echo "Configurazione Cloud-Init..."
qm set $VMID --ciuser $VM_USER
# Aggiungi password (opzionale ma utile)
CLOUD_INIT_PASSWORD=$(openssl rand -base64 12)
qm set $VMID --cipasswd ${CLOUD_INIT_PASSWORD}
echo "Password generata per l'utente cloud-init (${VM_USER}): ${CLOUD_INIT_PASSWORD}"
# Aggiungi chiave SSH se specificata
if [ -n "$SSH_PUB_KEY" ]; then
    qm set $VMID --sshkeys "$SSH_PUB_KEY"
fi
# Configura rete con IP statico
qm set $VMID --ip net0 ip=${NETWORK_IP},gw=${NETWORK_GW}
qm set $VMID --nameserver ${NETWORK_DNS}
qm set $VMID --ci .
check_command "Configurazione Cloud-Init"

# Abilita Qemu Guest Agent
echo "Abilitazione Qemu Guest Agent..."
qm set $VMID --agent 1
check_command "Abilitazione Guest Agent"

# Avvia la VM
echo "Avvio della VM ${VMNAME}..."
qm start $VMID
check_command "Avvio VM"

# Attendi che il guest agent sia pronto prima di installare OpenWisp
wait_for_agent

# --- Installazione OpenWisp e Configurazione Web Server ---
echo "Avvio installazione OpenWisp e configurazione web server all'interno della VM..."

# Usiamo 'EOF' tra apici per prevenire l'espansione di variabili bash qui
INSTALL_CMD=$(cat <<'EOF'
#!/bin/bash

# Directory di installazione di OpenWisp
OPENWISP_DIR="/home/ubuntu/openwisp-config"
VENV_DIR="${OPENWISP_DIR}/.venv"
VM_USER="ubuntu" # Deve corrispondere all'utente cloud-init

# Aggiorna il sistema
sudo apt update && sudo apt upgrade -y
if [ $? -ne 0 ]; then echo "Errore aggiornamento sistema"; exit 1; fi

# Installa dipendenze
sudo apt install -y git python3 python3-dev python3-setuptools python3-venv build-essential mariadb-server mariadb-client libmariadbclient-dev nginx gunicorn
if [ $? -ne 0 ]; then echo "Errore installazione dipendenze (git, python, mariadb, nginx, gunicorn)"; exit 1; fi

# Configura MariaDB
# Le password vengono passate dall'esterno tramite lo script principale Proxmox
DB_ROOT_PASSWORD_INNER="${DB_ROOT_PASSWORD_PLACEHOLDER}"
DB_OPENWISP_PASSWORD_INNER="${DB_OPENWISP_PASSWORD_PLACEHOLDER}"
DB_NAME_INNER="openwisp"
DB_USER_INNER="openwisp"

sudo mysql <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD_INNER}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE ${DB_NAME_INNER} CHARACTER SET utf8 COLLATE utf8_general_ci;
GRANT ALL ON ${DB_NAME_INNER}.* TO '${DB_USER_INNER}'@'localhost' IDENTIFIED BY '${DB_OPENWISP_PASSWORD_INNER}';
FLUSH PRIVILEGES;
MYSQL_SCRIPT
if [ $? -ne 0 ]; then echo "Errore configurazione MariaDB"; exit 1; fi
echo "MariaDB configurato."


# Clona repository OpenWisp
git clone https://github.com/openwisp/openwisp-config.git "${OPENWISP_DIR}"
if [ $? -ne 0 ]; then echo "Errore clone repository OpenWisp"; exit 1; fi

# Entra nella directory e crea virtual environment
cd "${OPENWISP_DIR}" || exit 1 # Esci se il cd fallisce
python3 -m venv "${VENV_DIR}"
if [ $? -ne 0 ]; then echo "Errore creazione virtual environment"; exit 1; fi

# Attiva virtual environment e installa OpenWisp
source "${VENV_DIR}/bin/activate"
pip install -r requirements.txt
if [ $? -ne 0 ]; then echo "Errore installazione OpenWisp con pip"; exit 1; fi

# Configura settings.py (aggiorna la configurazione del database e ALLOWED_HOSTS)
# L'indirizzo IP della VM viene passato dall'esterno
NETWORK_IP_INNER="${NETWORK_IP_PLACEHOLDER%%/*}"

sed -i "s/'ENGINE': 'django.db.backends.sqlite3'/'ENGINE': 'django.db.backends.mysql'/g" config/settings.py
sed -i "s/'NAME': os.path.join(BASE_DIR, 'db.sqlite3')/'NAME': '${DB_NAME_INNER}'/g" config/settings.py
sed -i "/'NAME': '${DB_NAME_INNER}'/a \ \ \ \ \ \ \ \ 'USER': '${DB_USER_INNER}'," config/settings.py
sed -i "/'USER': '${DB_USER_INNER}',/a \ \ \ \ \ \ \ \ 'PASSWORD': '${DB_OPENWISP_PASSWORD_INNER}'," config/settings.py
sed -i "/'PASSWORD': '${DB_OPENWISP_PASSWORD_INNER}',/a \ \ \ \ \ \ \ \ 'HOST': 'localhost'," config/settings.py
sed -i "/'HOST': 'localhost',/a \ \ \ \ \ \ \ \ 'PORT': ''," config/settings.py
# Aggiungi l'IP della VM e localhost agli ALLOWED_HOSTS
sed -i "s/ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = \['${NETWORK_IP_INNER}', 'localhost'\]/g" config/settings.py
if [ $? -ne 0 ]; then echo "Errore configurazione settings.py"; exit 1; fi
echo "File settings.py configurato."

# Esegui le migrazioni del database
python manage.py migrate --noinput
if [ $? -ne 0 ]; then echo "Errore esecuzione migrazioni database"; exit 1; fi
echo "Migrazioni database completate."

# Raccogli i file statici
python manage.py collectstatic --noinput
if [ $? -ne 0 ]; then echo "Errore raccolta file statici"; exit 1; fi
echo "File statici raccolti."

# Disattiva virtual environment
deactivate

# --- Configurazione Gunicorn ---
echo "Configurazione Gunicorn..."
# Crea un service file systemd per Gunicorn
sudo tee /etc/systemd/system/gunicorn.service > /dev/null <<GUNICORN_EOF
[Unit]
Description=gunicorn daemon for OpenWISP
After=network.target

[Service]
User=${VM_USER}
Group=${VM_USER}
WorkingDirectory=${OPENWISP_DIR}
ExecStart=${VENV_DIR}/bin/gunicorn --workers 3 --bind unix:${OPENWISP_DIR}/openwisp.sock config.wsgi:application

[Install]
WantedBy=multi-user.target
GUNICORN_EOF
if [ $? -ne 0 ]; then echo "Errore creazione service file Gunicorn"; exit 1; fi

# Ricarica systemd, abilita e avvia Gunicorn
sudo systemctl daemon-reload
sudo systemctl enable gunicorn
sudo systemctl start gunicorn
if [ $? -ne 0 ]; then echo "Errore avvio o abilitazione Gunicorn"; exit 1; fi
echo "Servizio Gunicorn avviato e abilitato."

# --- Configurazione Nginx ---
echo "Configurazione Nginx..."
# Rimuovi la configurazione Nginx di default
sudo rm -f /etc/nginx/sites-enabled/default

# Crea la configurazione Nginx per OpenWisp
sudo tee /etc/nginx/sites-available/openwisp > /dev/null <<NGINX_EOF
server {
    listen 80;
    server_name ${NETWORK_IP_INNER};

    location = /favicon.ico { access_log off; log_not_found off; }
    location /static/ {
        root ${OPENWISP_DIR};
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:${OPENWISP_DIR}/openwisp.sock;
    }
}
NGINX_EOF
if [ $? -ne 0 ]; then echo "Errore creazione configurazione Nginx"; exit 1; fi

# Crea il link simbolico per abilitare la configurazione Nginx
sudo ln -s /etc/nginx/sites-available/openwisp /etc/nginx/sites-enabled/
if [ $? -ne 0 ]; then echo "Errore creazione link simbolico Nginx"; exit 1; fi

# Testa la configurazione Nginx e riavvia
sudo nginx -t
if [ $? -ne 0 ]; then echo "Errore test configurazione Nginx"; exit 1; fi
sudo systemctl restart nginx
if [ $? -ne 0 ]; then echo "Errore riavvio Nginx"; exit 1; fi
sudo systemctl enable nginx
if [ $? -ne 0 ]; then echo "Errore abilitazione Nginx"; exit 1; fi
echo "Nginx configurato e riavviato."

# --- Configurazione Firewall (UFW) ---
# Controlla se UFW è attivo e, in tal caso, apri la porta 80
if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    echo "Configurazione UFW per permettere il traffico HTTP (porta 80)..."
    sudo ufw allow 80/tcp comment 'Allow HTTP for OpenWisp'
    if [ $? -ne 0 ]; then echo "Attenzione: Errore configurazione UFW."; fi
    sudo ufw reload
    if [ $? -ne 0 ]; then echo "Attenzione: Errore ricaricamento UFW."; fi
    echo "Regola UFW per la porta 80 aggiunta."
else
    echo "UFW non attivo o non installato. Salto la configurazione firewall."
fi


echo "Installazione e configurazione base di OpenWisp e web server completate."
echo "PASSI SUCCESSIVI FONDAMENTALI:"
echo "1. Connettiti alla VM via SSH: ssh ${VM_USER}@${NETWORK_IP_INNER}"
echo "2. Entra nella directory di OpenWisp: cd ${OPENWISP_DIR}"
echo "3. Attiva il virtual environment: source ${VENV_DIR}/bin/activate"
echo "4. CREA L'UTENTE SUPERUSER per accedere all'interfaccia web (questo passaggio è interattivo e non automatizzabile in sicurezza nello script):"
echo "   python manage.py createsuperuser"
echo "   Segui le istruzioni per creare l'utente amministratore."
echo "5. Disattiva il virtual environment: deactivate"

EOF
)

# Sostituisci i placeholder delle password e dell'IP prima di eseguire il comando
INSTALL_CMD=$(echo "$INSTALL_CMD" | sed "s|\${DB_ROOT_PASSWORD_PLACEHOLDER}|${DB_ROOT_PASSWORD}|g")
INSTALL_CMD=$(echo "$INSTALL_CMD" | sed "s|\${DB_OPENWISP_PASSWORD_PLACEHOLDER}|${DB_OPENWISP_PASSWORD}|g")
INSTALL_CMD=$(echo "$INSTALL_CMD" | sed "s|\${NETWORK_IP_PLACEHOLDER}|${NETWORK_IP}|g")


# Esegui i comandi di installazione nella VM
execute_in_vm "$INSTALL_CMD"

# --- Fine Script ---
echo "--------------------------------------------------"
echo "VM ${VMNAME} (ID ${VMID}) creata e configurata."
echo "Installazione base di OpenWisp con Nginx e Gunicorn completata."
echo "Indirizzo IP della VM: ${NETWORK_IP%%/*}"
echo "Nome utente cloud-init: ${VM_USER}"
echo "Password utente cloud-init generata: ${CLOUD_INIT_PASSWORD}"
echo "Password root MariaDB generata: ${DB_ROOT_PASSWORD}"
echo "Password utente OpenWisp MariaDB generata: ${DB_OPENWISP_PASSWORD}"
echo "--------------------------------------------------"
echo "Accesso all'interfaccia web di OpenWISP:"
echo "L'interfaccia web dovrebbe essere accessibile all'indirizzo:"
echo "http://${NETWORK_IP%%/*}"
echo ""
echo "PASSO FONDAMENTALE MANCANTE:"
echo "Devi creare l'utente amministratore (superuser) di OpenWISP."
echo "Connettiti alla VM tramite SSH (utente '${VM_USER}', IP '${NETWORK_IP%%/*}', password generata sopra) ed esegui i seguenti comandi:"
echo "cd /home/${VM_USER}/openwisp-config"
echo "source .venv/bin/activate"
echo "python manage.py createsuperuser"
echo "Segui le istruzioni a schermo per creare l'utente superuser."
echo "Dopo aver creato l'utente, potrai accedere all'interfaccia web con le credenziali scelte."
