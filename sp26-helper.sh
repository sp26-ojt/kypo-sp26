#!/bin/bash
# =================================================================
# KYPO SP26 - CÔNG CỤ QUẢN LÝ CÀI ĐẶT TỰ ĐỘNG
# Target Repo: https://github.com/sp26-ojt/kypo-sp26.git
# =================================================================

REPO_URL="https://github.com/sp26-ojt/kypo-sp26.git"
REPO_DIR="kypo-sp26"
DEBUG_FILE="debug.txt"

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
    echo "5. CÀI PROXY CÔNG KHAI (Cài Nginx trên Public Host)"
    echo "6. THOÁT"
    echo "-------------------------------------------------------"
    read -p "Lựa chọn của bạn (1-6): " main_opt
}

# --- LỰA CHỌN 1: BUILD ---
run_build() {
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

    # --- Nhập Public IP cho build ---
    echo "-------------------------------------------------------"
    echo "KYPO_PUBLIC_HOST: IP công khai của server này."
    echo "Dùng để cấu hình Keycloak issuer và các service URL."
    local default_build_ip="42.115.38.85"
    read -p "Nhập KYPO_PUBLIC_HOST [$default_build_ip]: " input_build_ip
    local KYPO_PUBLIC_HOST="${input_build_ip:-$default_build_ip}"

    if ! echo "$KYPO_PUBLIC_HOST" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "Lỗi: '$KYPO_PUBLIC_HOST' không phải địa chỉ IP hợp lệ."
        read -p "Nhấn Enter để quay lại..."
        cd ..
        return
    fi

    # --- Xác nhận cấu hình trước khi build ---
    echo "--- Xác nhận cấu hình ---"
    echo ""
    echo "======================================================="
    echo "XÁC NHẬN CẤU HÌNH"
    echo "-------------------------------------------------------"
    echo "KYPO_PUBLIC_HOST: $KYPO_PUBLIC_HOST"
    echo "Images dir: $REPO_DIR/$HTTP_DIR/"
    echo "  Tên file cần có:"
    for item in "${IMAGES[@]}"; do
        echo "    - $(echo "$item" | cut -d'|' -f1)"
    done
    echo "-------------------------------------------------------"
    echo "Lưu ý: head_host sẽ được lấy tự động từ OpenStack"
    echo "       sau khi Terraform deploy xong (cluster_ip output)."
    echo "-------------------------------------------------------"
    read -p "Nhấn Enter để bắt đầu BUILD..."

    # --- [4/4] Vagrant Up ---
    echo "--- [4/4] KYPO BUILD (vagrant up via Docker) ---"
    screen -S kypo_build -X quit 2>/dev/null

    VAGRANT_CMD="docker run -it --rm \
  -e LIBVIRT_DEFAULT_URI \
  -e KYPO_PUBLIC_HOST=${KYPO_PUBLIC_HOST} \
  -v /var/run/libvirt/:/var/run/libvirt/ \
  -v ~/.vagrant.d:/.vagrant.d \
  -v \$(realpath \"\${PWD}\"):\${PWD} \
  -w \"\${PWD}\" \
  --network host \
  vagrantlibvirt/vagrant-libvirt:latest \
  vagrant up"

    screen -dmS kypo_build bash -c "$VAGRANT_CMD 2>&1 | tee ../$DEBUG_FILE"

    echo "-------------------------------------------------------"
    echo "BUILD ĐÃ KHỞI ĐỘNG!"
    echo "  Theo dõi log: tail -f $PWD/../$DEBUG_FILE"
    echo "  Live terminal: screen -r kypo_build"
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

# --- LỰA CHỌN 5: CÀI PROXY CÔNG KHAI ---
setup_public_proxy() {
    clear
    echo "======================================================="
    echo "   CÀI NGINX REVERSE PROXY TRÊN PUBLIC HOST"
    echo "======================================================="
    echo "Script này sẽ cài Nginx và cấu hình forward traffic"
    echo "từ Public Host về KYPO_Node (10.1.2.157)."
    echo "-------------------------------------------------------"

    # Nhập public IP
    local default_ip="42.115.38.85"
    read -p "Nhập Public IP của server này [$default_ip]: " input_ip
    local public_ip="${input_ip:-$default_ip}"

    # Validate định dạng IP cơ bản
    if ! echo "$public_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "Lỗi: '$public_ip' không phải địa chỉ IP hợp lệ."
        read -p "Nhấn Enter để quay lại..."
        return
    fi

    echo ""
    echo "-------------------------------------------------------"
    echo "Cấu hình sẽ dùng:"
    echo "  KYPO_PUBLIC_IP : $public_ip"
    echo "  KYPO_NODE_IP   : 10.1.2.157"
    echo "-------------------------------------------------------"
    read -p "Xác nhận cài đặt? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Đã hủy."
        read -p "Nhấn Enter để quay lại..."
        return
    fi

    # Xác định đường dẫn script
    local script_path
    if [ -f "$REPO_DIR/scripts/05-public-proxy-setup.sh" ]; then
        script_path="$REPO_DIR/scripts/05-public-proxy-setup.sh"
    elif [ -f "scripts/05-public-proxy-setup.sh" ]; then
        script_path="scripts/05-public-proxy-setup.sh"
    else
        echo "Lỗi: Không tìm thấy scripts/05-public-proxy-setup.sh"
        read -p "Nhấn Enter để quay lại..."
        return
    fi

    echo ""
    echo "--- Đang chạy proxy setup ---"
    KYPO_PUBLIC_IP="$public_ip" sudo -E bash "$script_path"

    echo ""
    read -p "Nhấn Enter để về Menu..."
}

# --- MAIN LOOP ---
while true; do
    show_menu
    case $main_opt in
        1) run_build ;;
        2) read_logs ;;
        3) soft_restart ;;
        4) force_cleanup ;;
        5) setup_public_proxy ;;
        6) exit 0 ;;
    esac
done
