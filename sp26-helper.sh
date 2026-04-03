#!/bin/bash
# =================================================================
# KYPO SP26 - CÔNG CỤ QUẢN LÝ CÀI ĐẶT TỰ ĐỘNG
# Target Repo: https://github.com/sp26-ojt/kypo-sp26.git
# =================================================================

REPO_URL="https://github.com/sp26-ojt/kypo-sp26.git"
REPO_DIR="kypo-sp26"
DEBUG_FILE="debug.txt"
CONFIG_FILE="sp26.conf"

# --- MENU CHÍNH ---
show_menu() {
    clear
    echo "======================================================="
    echo "   KYPO SP26 - CÔNG CỤ QUẢN LÝ CÀI ĐẶT TỰ ĐỘNG"
    echo "======================================================="
    echo "1. BUILD MỚI (Khởi chạy quy trình chuẩn 4 bước)"
    echo "2. XEM LOG HỆ THỐNG (SSH vào VM & Chọn Log)"
    echo "3. RESTART MỀM (Khởi động lại dịch vụ khi bị nghẽn)"
    echo "4. DỌN DẸP & RESET (Xóa tiến độ cũ để làm lại)"
    echo "5. SETUP NGINX PROXY (Re-setup truy cập qua Public IP)"
    echo "6. THOÁT"
    echo "-------------------------------------------------------"
    read -p "Lựa chọn của bạn (1-6): " main_opt
}

# --- LỰA CHỌN 1: BUILD ---
run_build() {
    # Hỏi public IP — bắt buộc để KYPO dùng đúng head_host
    echo "-------------------------------------------------------"
    echo "NHẬP PUBLIC IP CỦA SERVER NÀY:"
    echo "  KYPO sẽ dùng IP này làm địa chỉ truy cập portal."
    echo "  (Keycloak redirect URI, TLS cert đều config theo IP này)"
    echo "-------------------------------------------------------"
    while true; do
        read -r -p "Public IP: " PUBLIC_IP < /dev/tty
        PUBLIC_IP="$(echo "$PUBLIC_IP" | tr -d '[:space:]')"
        if [ -n "$PUBLIC_IP" ]; then
            echo "PUBLIC_IP=$PUBLIC_IP" > "$CONFIG_FILE"
            echo "Đã lưu Public IP: $PUBLIC_IP"
            break
        fi
        echo "Vui lòng nhập IP, không được để trống."
    done
    echo ""

    echo "--- [1/4] Syncing repository ---"
    if [ ! -d "$REPO_DIR" ]; then
        echo "Cloning repository..."
        git clone "$REPO_URL"
    else
        echo "Repository '$REPO_DIR' đã tồn tại. Đang force overwrite..."
        cd "$REPO_DIR" || exit
        git fetch --all
        git reset --hard origin/main || git reset --hard origin/master
        git clean -fd
        cd ..
    fi

    cd "$REPO_DIR" || { echo "Không thể vào thư mục $REPO_DIR"; exit 1; }
    chmod +x scripts/*.sh 2>/dev/null

    # --- [2/5] Cài đặt dependencies ---
    echo "--- [2/4] Installing system dependencies ---"
    sudo apt update
    sudo apt install -y qemu-kvm libvirt-daemon libvirt-clients bridge-utils \
        virt-manager docker.io screen wget curl git

    if ! command -v croc &> /dev/null; then
        echo "Installing croc..."
        curl https://getcroc.schollz.com | bash
    fi

    # --- [3/5] Chuẩn bị Images ---
    echo "--- [3/4] Image Preparation ---"
    HTTP_DIR="http"
    mkdir -p "$HTTP_DIR"

    # Tên file chuẩn theo images.tf trong repo
    IMAGES=(
        "noble-server-cloudimg-amd64.img|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
        "debian-12-genericcloud-amd64.qcow2|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
        "kali.qcow2|https://gm7ve.upcloudobjects.com/crczp-images/kali.qcow2"
        "ubuntu-noble-man.qcow2|https://gm7ve.upcloudobjects.com/crczp-images/ubuntu-noble-man.qcow2"
    )

    while true; do
        echo "-------------------------------------------------------"
        echo "LỰA CHỌN THIẾT LẬP IMAGE:"
        echo "1. Tôi đã có sẵn file trên Server (copy vào http/ rồi)"
        echo "2. Chuyển file từ máy cá nhân qua Server (dùng croc)"
        echo "3. Tải mới từ Internet"
        echo "-------------------------------------------------------"
        read -p "Chọn phương thức (1/2/3): " img_option
        case $img_option in
        1)
            echo "[HƯỚNG DẪN]"
            echo "Copy 4 file image vào thư mục: $REPO_DIR/$HTTP_DIR/"
            echo "Tên file cần có:"
            for item in "${IMAGES[@]}"; do
                echo "  - $(echo "$item" | cut -d'|' -f1)"
            done
            echo "Nếu tên file khác, hãy sửa $HTTP_DIR/images.tf cho khớp."
            read -p "Nhấn Enter sau khi đã copy xong..."
            break
            ;;
        2)
            echo "======================================================="
            echo "[HƯỚNG DẪN CHUYỂN FILE QUA CROC]"
            echo "-------------------------------------------------------"
            echo "BƯỚC A (Máy cá nhân - MÁY GỬI):"
            echo "  croc send <tên_file_image>"
            echo "  -> Copy mã CODE được hiển thị."
            echo ""
            echo "BƯỚC B (Server này - MÁY NHẬN):"
            echo "  cd $REPO_DIR/$HTTP_DIR"
            echo "  croc <mã_code>"
            echo "======================================================="
            read -p "Nhấn Enter để tiếp tục..."
            break
            ;;
        3)
            echo "Đang tải images..."
            for item in "${IMAGES[@]}"; do
                FILENAME=$(echo "$item" | cut -d'|' -f1)
                URL=$(echo "$item" | cut -d'|' -f2)
                if [ ! -f "$HTTP_DIR/$FILENAME" ]; then
                    echo "Tải $FILENAME..."
                    wget -O "$HTTP_DIR/$FILENAME" "$URL"
                else
                    echo "File $FILENAME đã tồn tại, bỏ qua."
                fi
            done
            break
            ;;
        *)
            echo "Lựa chọn không hợp lệ!"
            ;;
        esac
    done

    # --- Xác nhận cấu hình trước khi build ---
    echo "--- Xác nhận cấu hình ---"
    echo ""
    echo "======================================================="
    echo "XÁC NHẬN CẤU HÌNH"
    echo "-------------------------------------------------------"
    echo "Images dir: $REPO_DIR/$HTTP_DIR/"
    echo "  Tên file cần có:"
    for item in "${IMAGES[@]}"; do
        echo "    - $(echo "$item" | cut -d'|' -f1)"
    done
    echo "-------------------------------------------------------"
    echo "Lưu ý: KYPO sẽ dùng Public IP $PUBLIC_IP làm head_host."
    echo "       Nginx proxy sẽ tự được setup sau khi vagrant up xong."
    echo "-------------------------------------------------------"
    read -p "Nhấn Enter để bắt đầu BUILD..."

    # --- [4/4] Vagrant Up ---
    echo "--- [4/4] KYPO BUILD (vagrant up via Docker) ---"
    screen -S kypo_build -X quit 2>/dev/null

    REPO_ABS="$(realpath "${PWD}")"

    # Ghi nginx setup script ra file tạm để screen gọi sau khi vagrant up xong
    NGINX_SETUP_SCRIPT="/tmp/kypo_nginx_setup_$$.sh"
    cat > "$NGINX_SETUP_SCRIPT" << NGINX_SCRIPT
#!/bin/bash
set -e
PUBLIC_IP="$PUBLIC_IP"
CERT_DIR="/etc/nginx/ssl/kypo"

echo "=== Cài đặt nginx ==="
apt-get update -qq && apt-get install -y --reinstall nginx openssl

mkdir -p "\$CERT_DIR"
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "\$CERT_DIR/key.pem" \
    -out "\$CERT_DIR/cert.pem" \
    -subj "/CN=\$PUBLIC_IP" \
    -addext "subjectAltName=IP:\$PUBLIC_IP" 2>/dev/null

echo "=== Lấy cluster_ip từ VM ==="
CLUSTER_IP=\$(docker run --rm \
    -e LIBVIRT_DEFAULT_URI \
    -v /var/run/libvirt/:/var/run/libvirt/ \
    -v ~/.vagrant.d:/.vagrant.d \
    -v "$REPO_ABS":"$REPO_ABS" \
    -w "$REPO_ABS" \
    --network host \
    vagrantlibvirt/vagrant-libvirt:latest \
    vagrant ssh -- -t "cd /root/devops-tf-deployment/tf-openstack-base && tofu output -raw cluster_ip 2>/dev/null" 2>/dev/null | tr -d '\r\n ')

if [ -z "\$CLUSTER_IP" ]; then
    echo "WARN: Không lấy được cluster_ip, dùng 10.1.2.10 làm fallback"
    CLUSTER_IP="10.1.2.10"
fi
echo "cluster_ip = \$CLUSTER_IP"

cat > /etc/nginx/sites-available/kypo-proxy << EOF
# KYPO Portal + Keycloak — HTTPS reverse proxy
server {
    listen 443 ssl;
    server_name \$PUBLIC_IP;

    ssl_certificate     \$CERT_DIR/cert.pem;
    ssl_certificate_key \$CERT_DIR/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    proxy_buffer_size        128k;
    proxy_buffers            4 256k;
    proxy_busy_buffers_size  256k;

    location / {
        proxy_pass            https://\$CLUSTER_IP;
        proxy_ssl_verify      off;
        proxy_ssl_server_name on;
        proxy_ssl_name        \$PUBLIC_IP;
        proxy_set_header      Host              \$PUBLIC_IP;
        proxy_set_header      X-Real-IP         \\\$remote_addr;
        proxy_set_header      X-Forwarded-For   \\\$proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto https;
        proxy_read_timeout    300;
        proxy_connect_timeout 300;
        proxy_http_version    1.1;
        proxy_set_header      Upgrade           \\\$http_upgrade;
        proxy_set_header      Connection        "upgrade";
    }
}

# OpenStack Horizon — HTTP proxy
server {
    listen 8080;
    server_name \$PUBLIC_IP;

    location / {
        proxy_pass         http://10.1.2.10;
        proxy_set_header   Host            \\\$host;
        proxy_set_header   X-Real-IP       \\\$remote_addr;
        proxy_set_header   X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_read_timeout 120;
    }
}
EOF

ln -sf /etc/nginx/sites-available/kypo-proxy /etc/nginx/sites-enabled/kypo-proxy
rm -f /etc/nginx/sites-enabled/default 2>/dev/null
nginx -t && systemctl enable nginx && systemctl restart nginx

echo "======================================================="
echo "NGINX PROXY SẴN SÀNG!"
echo "  KYPO Portal : https://\$PUBLIC_IP/"
echo "  Horizon     : http://\$PUBLIC_IP:8080/"
echo "  (Browser cảnh báo self-signed cert — bấm Advanced > Proceed)"
echo "======================================================="
NGINX_SCRIPT
    chmod +x "$NGINX_SETUP_SCRIPT"

    VAGRANT_CMD="docker run -it --rm \
  -e LIBVIRT_DEFAULT_URI \
  -e PUBLIC_IP=$PUBLIC_IP \
  -v /var/run/libvirt/:/var/run/libvirt/ \
  -v ~/.vagrant.d:/.vagrant.d \
  -v \$(realpath \"\${PWD}\"):\${PWD} \
  -w \"\${PWD}\" \
  --network host \
  vagrantlibvirt/vagrant-libvirt:latest \
  vagrant up"

    # vagrant up chạy trong Docker, nginx setup chạy trực tiếp trên host sau đó
    screen -dmS kypo_build bash -c "
$VAGRANT_CMD 2>&1 | tee ../$DEBUG_FILE
echo '--- vagrant up done (exit='\${PIPESTATUS[0]}') ---' | tee -a ../$DEBUG_FILE
sudo bash $NGINX_SETUP_SCRIPT 2>&1 | tee -a ../$DEBUG_FILE
rm -f $NGINX_SETUP_SCRIPT
"

    echo "-------------------------------------------------------"
    echo "BUILD ĐÃ KHỞI ĐỘNG!"
    echo "  Theo dõi log: tail -f $PWD/../$DEBUG_FILE"
    echo "  Live terminal: screen -r kypo_build"
    echo "  Sau khi xong: https://$PUBLIC_IP/"
    echo "-------------------------------------------------------"
    cd ..
    read -p "Nhấn Enter để về Menu..."
}

# --- LỰA CHỌN 2: XEM LOG ---
read_logs() {
    clear
    echo "======================================================="
    echo "   TRUY CẬP MÁY ẢO & QUẢN LÝ HỆ THỐNG"
    echo "======================================================="

    if [ ! -d "$REPO_DIR" ]; then
        echo "Lỗi: Không tìm thấy thư mục $REPO_DIR."
        read -p "Nhấn Enter để quay lại..."
        return
    fi

    cd "$REPO_DIR" || exit

    LOG_COMMAND="sudo bash --login -c '
ulimit -n 65536
sysctl -w fs.inotify.max_user_instances=512 > /dev/null 2>&1
sysctl -w fs.inotify.max_user_watches=524288 > /dev/null 2>&1
while true; do
    echo \"\"
    echo \"============================================\"
    echo \"   KYPO SYSTEM MANAGEMENT MENU (VM)\"
    echo \"============================================\"
    echo \"1. Xem danh sách Pods (Tất cả Namespace)\"
    echo \"2. Xem Log: Sandbox Service\"
    echo \"3. Xem Log: Ansible Worker\"
    echo \"4. Xem Log: UAG Service\"
    echo \"5. Xem Log: Training Service\"
    echo \"6. Mở Terminal tự do\"
    echo \"7. Thoát\"
    echo \"--------------------------------------------\"
    read -p \"Lựa chọn (1-7): \" choice
    case \$choice in
        1) kubectl get pods -A; read -p \"Nhấn Enter...\" ;;
        2) kubectl logs -l \"app.kubernetes.io/name=sandbox-service\" -n crczp --tail=50; read -p \"Ấn Enter để quay lại menu...\" ;;
        3) kubectl logs -l \"app.kubernetes.io/name=sandbox-service-worker-ansible\" -n crczp --tail=50; read -p \"Ấn Enter để quay lại menu...\" ;;
        4) kubectl logs -l \"app.kubernetes.io/name=uag-service\" -n crczp --tail=50; read -p \"Ấn Enter để quay lại menu...\" ;;
        5) kubectl logs -l \"app.kubernetes.io/name=training-service\" -n crczp --tail=50; read -p \"Ấn Enter để quay lại menu...\" ;;
        6) echo \"Gõ exit để quay lại\"; /bin/bash ;;
        7) exit 0 ;;
        *) echo \"Lựa chọn không hợp lệ!\" ;;
    esac
done'"

    docker run -it --rm \
        -e LIBVIRT_DEFAULT_URI \
        -v /var/run/libvirt/:/var/run/libvirt/ \
        -v ~/.vagrant.d:/.vagrant.d \
        -v "$(realpath "${PWD}")":"${PWD}" \
        -w "${PWD}" \
        --network host \
        vagrantlibvirt/vagrant-libvirt:latest \
        vagrant ssh -- -t "$LOG_COMMAND"

    cd ..
    read -p "Nhấn Enter để quay lại Menu..."
}

# --- LỰA CHỌN 3: RESTART MỀM ---
_run_in_vm() {
    # Chạy lệnh bên trong VM qua vagrant ssh
    local cmd="$1"
    if [ ! -d "$REPO_DIR" ]; then
        echo "Lỗi: Không tìm thấy thư mục $REPO_DIR."
        return 1
    fi
    cd "$REPO_DIR" || return 1
    docker run -it --rm \
        -e LIBVIRT_DEFAULT_URI \
        -v /var/run/libvirt/:/var/run/libvirt/ \
        -v ~/.vagrant.d:/.vagrant.d \
        -v "$(realpath "${PWD}")":"${PWD}" \
        -w "${PWD}" \
        --network host \
        vagrantlibvirt/vagrant-libvirt:latest \
        vagrant ssh -- -t "sudo bash -c '$cmd'"
    cd ..
}

soft_restart() {
    while true; do
        clear
        echo "======================================================="
        echo "   RESTART MỀM - KYPO SERVICES (VM)"
        echo "======================================================="
        echo "1. Restart TẤT CẢ deployments trong namespace crczp"
        echo "2. Restart một deployment cụ thể"
        echo "3. Xem trạng thái Pods hiện tại"
        echo "4. Xóa Pod bị CrashLoopBackOff / Error (tự tạo lại)"
        echo "5. Restart CoreDNS"
        echo "6. Fix: too many open files (tăng inotify limit)"
        echo "7. Quay lại Menu chính"
        echo "-------------------------------------------------------"
        read -p "Lựa chọn (1-7): " rs_opt

        case $rs_opt in
        1)
            echo "Đang rollout restart tất cả deployments trong namespace crczp..."
            _run_in_vm "kubectl rollout restart deployment -n crczp"
            echo ""
            echo "Đợi pods ổn định..."
            _run_in_vm "kubectl rollout status deployment -n crczp --timeout=120s 2>/dev/null || true"
            read -p "Nhấn Enter..."
            ;;
        2)
            echo "Danh sách deployments trong namespace crczp:"
            _run_in_vm "kubectl get deployments -n crczp"
            echo ""
            read -p "Nhập tên deployment cần restart: " DEPLOY_NAME
            if [ -n "$DEPLOY_NAME" ]; then
                echo "Đang restart $DEPLOY_NAME..."
                _run_in_vm "kubectl rollout restart deployment/$DEPLOY_NAME -n crczp && kubectl rollout status deployment/$DEPLOY_NAME -n crczp --timeout=120s"
            fi
            read -p "Nhấn Enter..."
            ;;
        3)
            echo "Trạng thái Pods trong namespace crczp:"
            _run_in_vm "kubectl get pods -n crczp -o wide"
            echo ""
            echo "Pods bất thường (không Running/Completed):"
            _run_in_vm "kubectl get pods -n crczp --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || echo 'Tất cả pods đang Running.'"
            read -p "Nhấn Enter..."
            ;;
        4)
            echo "Đang xóa các pods bị lỗi (CrashLoopBackOff / Error / OOMKilled)..."
            _run_in_vm "kubectl get pods -n crczp --no-headers | grep -E 'CrashLoopBackOff|OOMKilled|Error' | tr -s ' ' | cut -d' ' -f1 | xargs -r kubectl delete pod -n crczp"
            echo "Pods lỗi đã bị xóa. Kubernetes sẽ tự tạo lại."
            read -p "Nhấn Enter..."
            ;;
        5)
            echo "Đang restart CoreDNS..."
            _run_in_vm "kubectl rollout restart deployment/coredns -n kube-system"
            read -p "Nhấn Enter..."
            ;;
        6)
            echo "Đang tăng inotify limits để fix 'too many open files'..."
            _run_in_vm "sysctl -w fs.inotify.max_user_instances=1024 && sysctl -w fs.inotify.max_user_watches=1048576 && sysctl -w fs.file-max=2097152 && echo 'fs.inotify.max_user_instances=1024' >> /etc/sysctl.conf && echo 'fs.inotify.max_user_watches=1048576' >> /etc/sysctl.conf && echo 'fs.file-max=2097152' >> /etc/sysctl.conf"
            echo "Đang restart các worker pods để áp dụng..."
            _run_in_vm "kubectl rollout restart deployment -n crczp"
            echo "Done. Kiểm tra lại log sau vài giây."
            read -p "Nhấn Enter..."
            ;;
        7)
            break
            ;;
        *)
            echo "Lựa chọn không hợp lệ!"
            sleep 1
            ;;
        esac
    done
}

# --- LỰA CHỌN 4: DỌN DẸP ---
force_cleanup() {
    echo "======================================================="
    echo "   CẢNH BÁO: HÀNH ĐỘNG NÀY SẼ XÓA TOÀN BỘ HỆ THỐNG"
    echo "======================================================="
    echo "Nhập chính xác tên repo để xác nhận: $REPO_DIR"
    echo "-------------------------------------------------------"
    read -p "Xác nhận: " CONFIRM_NAME

    if [ "$CONFIRM_NAME" != "$REPO_DIR" ]; then
        echo "Tên không khớp! Hủy bỏ."
        read -p "Nhấn Enter..."
        return
    fi

    echo "--- BẮT ĐẦU DỌN DẸP ---"
    sudo pkill screen 2>/dev/null

    if [ -d "$REPO_DIR" ]; then
        cd "$REPO_DIR" || exit
        echo "Đang chạy vagrant destroy..."
        docker run -it --rm \
            -e LIBVIRT_DEFAULT_URI \
            -v /var/run/libvirt/:/var/run/libvirt/ \
            -v ~/.vagrant.d:/.vagrant.d \
            -v "$(realpath "${PWD}")":"${PWD}" \
            -w "${PWD}" \
            --network host \
            vagrantlibvirt/vagrant-libvirt:latest \
            vagrant destroy -f
        rm -rf .vagrant
        cd ..
    fi

    DOCKER_IDS=$(docker ps -a | grep "vagrant-libvirt" | awk '{print $1}')
    [ -n "$DOCKER_IDS" ] && docker rm -f $DOCKER_IDS 2>/dev/null
    sudo pkill -9 vagrant 2>/dev/null

    echo "======================================================="
    echo "DỌN DẸP HOÀN TẤT!"
    echo "======================================================="
    read -p "Nhấn Enter..."
}

# --- LỰA CHỌN 5: NGINX PROXY (re-setup thủ công) ---
setup_nginx_proxy() {
    clear
    echo "======================================================="
    echo "   SETUP NGINX REVERSE PROXY (thủ công)"
    echo "======================================================="

    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi

    if [ -z "$PUBLIC_IP" ]; then
        read -p "Nhập Public IP của server: " PUBLIC_IP
        [ -z "$PUBLIC_IP" ] && echo "Cần nhập Public IP!" && read -p "Nhấn Enter..." && return
        echo "PUBLIC_IP=$PUBLIC_IP" > "$CONFIG_FILE"
    else
        echo "Public IP hiện tại: $PUBLIC_IP"
        read -p "Dùng IP này? (Enter = có, nhập IP mới để thay): " NEW_IP
        if [ -n "$NEW_IP" ]; then
            PUBLIC_IP="$NEW_IP"
            echo "PUBLIC_IP=$PUBLIC_IP" > "$CONFIG_FILE"
        fi
    fi

    REPO_ABS="$(realpath "$REPO_DIR" 2>/dev/null || echo "$PWD/$REPO_DIR")"
    NGINX_SETUP_SCRIPT="/tmp/kypo_nginx_manual_$$.sh"
    cat > "$NGINX_SETUP_SCRIPT" << NGINX_SCRIPT
#!/bin/bash
set -e
PUBLIC_IP="$PUBLIC_IP"
CERT_DIR="/etc/nginx/ssl/kypo"

apt-get update -qq && apt-get install -y nginx openssl

mkdir -p "\$CERT_DIR"
# Tạo lại cert nếu IP thay đổi
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "\$CERT_DIR/key.pem" \
    -out "\$CERT_DIR/cert.pem" \
    -subj "/CN=\$PUBLIC_IP" \
    -addext "subjectAltName=IP:\$PUBLIC_IP" 2>/dev/null

echo "Lấy cluster_ip từ VM..."
CLUSTER_IP=\$(docker run --rm \
    -e LIBVIRT_DEFAULT_URI \
    -v /var/run/libvirt/:/var/run/libvirt/ \
    -v ~/.vagrant.d:/.vagrant.d \
    -v "$REPO_ABS":"$REPO_ABS" \
    -w "$REPO_ABS" \
    --network host \
    vagrantlibvirt/vagrant-libvirt:latest \
    vagrant ssh -- -t "cd /root/devops-tf-deployment/tf-openstack-base && tofu output -raw cluster_ip 2>/dev/null" 2>/dev/null | tr -d '\r\n ')

[ -z "\$CLUSTER_IP" ] && CLUSTER_IP="10.1.2.10" && echo "WARN: fallback cluster_ip=10.1.2.10"
echo "cluster_ip = \$CLUSTER_IP"

cat > /etc/nginx/sites-available/kypo-proxy << EOF
# KYPO Portal + Keycloak — HTTPS reverse proxy
server {
    listen 443 ssl;
    server_name \$PUBLIC_IP;

    ssl_certificate     \$CERT_DIR/cert.pem;
    ssl_certificate_key \$CERT_DIR/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    proxy_buffer_size        128k;
    proxy_buffers            4 256k;
    proxy_busy_buffers_size  256k;

    location / {
        proxy_pass            https://\$CLUSTER_IP;
        proxy_ssl_verify      off;
        proxy_ssl_server_name on;
        proxy_ssl_name        \$PUBLIC_IP;
        proxy_set_header      Host              \$PUBLIC_IP;
        proxy_set_header      X-Real-IP         \\\$remote_addr;
        proxy_set_header      X-Forwarded-For   \\\$proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto https;
        proxy_read_timeout    300;
        proxy_connect_timeout 300;
        proxy_http_version    1.1;
        proxy_set_header      Upgrade           \\\$http_upgrade;
        proxy_set_header      Connection        "upgrade";
    }
}

# OpenStack Horizon — HTTP proxy
server {
    listen 8080;
    server_name \$PUBLIC_IP;

    location / {
        proxy_pass         http://10.1.2.10;
        proxy_set_header   Host            \\\$host;
        proxy_set_header   X-Real-IP       \\\$remote_addr;
        proxy_set_header   X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_read_timeout 120;
    }
}
EOF

ln -sf /etc/nginx/sites-available/kypo-proxy /etc/nginx/sites-enabled/kypo-proxy
rm -f /etc/nginx/sites-enabled/default 2>/dev/null
nginx -t && systemctl enable nginx && systemctl restart nginx

echo "======================================================="
echo "NGINX PROXY SẴN SÀNG!"
echo "  KYPO Portal : https://\$PUBLIC_IP/"
echo "  Horizon     : http://\$PUBLIC_IP:8080/"
echo "======================================================="
NGINX_SCRIPT
    chmod +x "$NGINX_SETUP_SCRIPT"
    sudo bash "$NGINX_SETUP_SCRIPT"
    rm -f "$NGINX_SETUP_SCRIPT"
    read -p "Nhấn Enter để quay lại Menu..."
}

# --- MAIN LOOP ---
while true; do
    show_menu
    case $main_opt in
        1) run_build ;;
        2) read_logs ;;
        3) soft_restart ;;
        4) force_cleanup ;;
        5) setup_nginx_proxy ;;
        6) exit 0 ;;
    esac
done
