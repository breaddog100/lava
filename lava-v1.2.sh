#!/bin/bash

# 节点安装功能
function install_node() {

    read -r -p "输入节点名称: " MONIKER

    sudo apt -q update
	sudo apt -qy install curl git jq lz4 build-essential
	sudo apt -qy upgrade

    sudo rm -rf /usr/local/go
	curl -Ls https://go.dev/dl/go1.20.14.linux-amd64.tar.gz | sudo tar -xzf - -C /usr/local
	eval $(echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/golang.sh)
	eval $(echo 'export PATH=$PATH:$HOME/go/bin' | tee -a $HOME/.profile)
    source $HOME/.profile

    # Clone project repository
	cd $HOME
	rm -rf lava
	git clone https://github.com/lavanet/lava.git
	cd lava
	git checkout v2.0.3
	
	# Build binaries
	export LAVA_BINARY=lavad
	make build
	
	# Prepare binaries for Cosmovisor
	mkdir -p $HOME/.lava/cosmovisor/genesis/bin
	mv build/lavad $HOME/.lava/cosmovisor/genesis/bin/
	rm -rf build
	
	# Create application symlinks
	sudo ln -s $HOME/.lava/cosmovisor/genesis $HOME/.lava/cosmovisor/current -f
	sudo ln -s $HOME/.lava/cosmovisor/current/bin/lavad /usr/local/bin/lavad -f
	
	# Download and install Cosmovisor
	go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.5.0

# Create service
sudo tee /etc/systemd/system/lava.service > /dev/null << EOF
[Unit]
Description=lava node service
After=network-online.target

[Service]
User=$USER
ExecStart=$(which cosmovisor) run start
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
Environment="DAEMON_HOME=$HOME/.lava"
Environment="DAEMON_NAME=lavad"
Environment="UNSAFE_SKIP_BACKUP=true"

[Install]
WantedBy=multi-user.target
EOF
	sudo systemctl daemon-reload
	sudo systemctl enable lava.service

	# Set node configuration
	lavad config chain-id lava-testnet-2
	lavad config keyring-backend test
	lavad config node tcp://localhost:14457
	
	# Initialize the node
	lavad init $MONIKER --chain-id lava-testnet-2
	
	# Download genesis and addrbook
	curl -Ls https://snapshots.kjnodes.com/lava-testnet/genesis.json > $HOME/.lava/config/genesis.json
	curl -Ls https://snapshots.kjnodes.com/lava-testnet/addrbook.json > $HOME/.lava/config/addrbook.json
	
	# Add seeds
	sed -i -e "s|^seeds *=.*|seeds = \"3f472746f46493309650e5a033076689996c8881@lava-testnet.rpc.kjnodes.com:14459\"|" $HOME/.lava/config/config.toml
	
	# Add peers
	PEERS=697750a8171090e8547c1749ff05c88c080f6350@131.153.158.137:26656,0e203a799d85b4dcd48556f3425a280f969bcf39@65.108.140.97:21656,8bffd46447eb797e8dc0020c9d2370bec85ea63f@136.243.174.230:34556,d1730b774b7c1d52dd9f6ae874a56de958aa147e@139.45.205.60:23656,332d88b6b56d9e8522c7650993b924ca63426cd6@144.91.69.5:14456
	sed -i.bak -e "s/^persistent_peers *=.*/persistent_peers = \"$PEERS\"/" $HOME/.lava/config/config.toml
	
	# Set minimum gas price
	sed -i -e "s|^minimum-gas-prices *=.*|minimum-gas-prices = \"0ulava\"|" $HOME/.lava/config/app.toml
	
	# Set pruning
	sed -i \
	  -e 's|^pruning *=.*|pruning = "custom"|' \
	  -e 's|^pruning-keep-recent *=.*|pruning-keep-recent = "100"|' \
	  -e 's|^pruning-keep-every *=.*|pruning-keep-every = "0"|' \
	  -e 's|^pruning-interval *=.*|pruning-interval = "19"|' \
	  $HOME/.lava/config/app.toml
	
	# Set custom ports
	sed -i -e "s%^proxy_app = \"tcp://127.0.0.1:26658\"%proxy_app = \"tcp://127.0.0.1:14458\"%; s%^laddr = \"tcp://127.0.0.1:26657\"%laddr = \"tcp://127.0.0.1:14457\"%; s%^pprof_laddr = \"localhost:6060\"%pprof_laddr = \"localhost:14460\"%; s%^laddr = \"tcp://0.0.0.0:26656\"%laddr = \"tcp://0.0.0.0:14456\"%; s%^prometheus_listen_addr = \":26660\"%prometheus_listen_addr = \":14466\"%" $HOME/.lava/config/config.toml
	sed -i -e "s%^address = \"tcp://0.0.0.0:1317\"%address = \"tcp://0.0.0.0:14417\"%; s%^address = \":8080\"%address = \":14480\"%; s%^address = \"0.0.0.0:9090\"%address = \"0.0.0.0:14490\"%; s%^address = \"0.0.0.0:9091\"%address = \"0.0.0.0:14491\"%; s%:8545%:14445%; s%:8546%:14446%; s%:6065%:14465%" $HOME/.lava/config/app.toml

	sed -i \
	  -e 's/timeout_commit = ".*"/timeout_commit = "30s"/g' \
	  -e 's/timeout_propose = ".*"/timeout_propose = "1s"/g' \
	  -e 's/timeout_precommit = ".*"/timeout_precommit = "1s"/g' \
	  -e 's/timeout_precommit_delta = ".*"/timeout_precommit_delta = "500ms"/g' \
	  -e 's/timeout_prevote = ".*"/timeout_prevote = "1s"/g' \
	  -e 's/timeout_prevote_delta = ".*"/timeout_prevote_delta = "500ms"/g' \
	  -e 's/timeout_propose_delta = ".*"/timeout_propose_delta = "500ms"/g' \
	  -e 's/skip_timeout_commit = ".*"/skip_timeout_commit = false/g' \
	  $HOME/.lava/config/config.toml
	  
	curl -L https://snapshots.kjnodes.com/lava-testnet/snapshot_latest.tar.lz4 | tar -Ilz4 -xf - -C $HOME/.lava
	[[ -f $HOME/.lava/data/upgrade-info.json ]] && cp $HOME/.lava/data/upgrade-info.json $HOME/.lava/cosmovisor/genesis/upgrade-info.json

	sudo systemctl start lava.service  
	  	  
    echo "正在拉取最新高度，耗时较长请耐心等待，不要断开连接..."
    sudo systemctl stop lava.service
	cp $HOME/.lava/data/priv_validator_state.json $HOME/.lava/priv_validator_state.json.backup
	rm -rf $HOME/.lava/data
	curl -L https://snapshots.kjnodes.com/lava-testnet/snapshot_latest.tar.lz4 | tar -Ilz4 -xf - -C $HOME/.lava
	mv $HOME/.lava/priv_validator_state.json.backup $HOME/.lava/data/priv_validator_state.json
	
	sudo systemctl daemon-reload
	sudo systemctl enable lava.service
	sudo systemctl start lava.service 

    echo "安装完成，节点已启动..."
}

function add_wallet() {
    read -r -p "请输入钱包名称: " wallet_name
    lavad keys add "$wallet_name"
    echo "钱包已创建，请备份钱包信息。"
}

function add_validator() {
    echo "钱包余额需大于20000ubbn，否则创建失败..."
    read -r -p "请输入你的验证者名称: " validator_name
    read -r -p "请输入你的钱包名称: " wallet_name
    lavad tx staking create-validator \
	--amount 1000000ulava \
	--pubkey $(lavad tendermint show-validator) \
	--moniker "$validator_name" \
	--identity "" \
	--details "Power by BeardDog" \
	--website "" \
	--chain-id lava-testnet-2 \
	--commission-rate 0.05 \
	--commission-max-rate 0.20 \
	--commission-max-change-rate 0.05 \
	--min-self-delegation 1 \
	--from $wallet_name \
	--gas-adjustment 1.4 \
	--gas auto \
	--gas-prices 0ulava \
	-y
}

function import_wallet() {
    read -r -p "请输入钱包名称: " wallet_name
    lavad keys add "$wallet_name" --recover
}

function check_balances() {
    read -r -p "请输入钱包地址: " wallet_address
    lavad q bank balances $(lavad keys show $wallet_address -a)
}

function check_sync_status() {
    lavad status 2>&1 | jq .SyncInfo
}

function check_service_status() {
    systemctl status lavad
}

function view_logs() {
    sudo journalctl -f -u babylond.service
}

function update_ports~(){

    # 检测端口
    local start_port=9000 # 可以根据需要调整起始搜索端口
    local needed_ports=7
    local count=0
    local ports=()
    while [ "$count" -lt "$needed_ports" ]; do
        if ! ss -tuln | grep -q ":$start_port " ; then
            ports+=($start_port)
            ((count++))
        fi
        ((start_port++))
    done
    echo "可用端口："
    for port in "${ports[@]}"; do
        echo -e "\033[0;32m$port\033[0m"
    done
    # 提示用户输入端口配置，允许使用默认值
    read -p "L2 HTTP端口 [默认: 8547]: " port_l2_execution_engine_http
    port_l2_execution_engine_http=${port_l2_execution_engine_http:-8547}
    read -p "L2 WS端口 [默认: 8548]: " port_l2_execution_engine_ws
    port_l2_execution_engine_ws=${port_l2_execution_engine_ws:-8548}
    read -p "请输入L2执行引擎Metrics端口 [默认: 6060]: " port_l2_execution_engine_metrics
    port_l2_execution_engine_metrics=${port_l2_execution_engine_metrics:-6060}
    read -p "请输入L2执行引擎P2P端口 [默认: 30306]: " port_l2_execution_engine_p2p
    port_l2_execution_engine_p2p=${port_l2_execution_engine_p2p:-30306}
    read -p "请输入证明者服务器端口 [默认: 9876]: " port_prover_server
    port_prover_server=${port_prover_server:-9876}
    read -p "请输入Prometheus端口 [默认: 9091]: " port_prometheus
    port_prometheus=${port_prometheus:-9091}
    read -p "请输入Grafana端口 [默认: 3001]: " port_grafana
    port_grafana=${port_grafana:-3001}
    
    sed -i "s|PORT_L2_EXECUTION_ENGINE_HTTP=.*|PORT_L2_EXECUTION_ENGINE_HTTP=${port_l2_execution_engine_http}|" .env
    sed -i "s|PORT_L2_EXECUTION_ENGINE_WS=.*|PORT_L2_EXECUTION_ENGINE_WS=${port_l2_execution_engine_ws}|" .env
    sed -i "s|PORT_L2_EXECUTION_ENGINE_METRICS=.*|PORT_L2_EXECUTION_ENGINE_METRICS=${port_l2_execution_engine_metrics}|" .env
    sed -i "s|PORT_L2_EXECUTION_ENGINE_P2P=.*|PORT_L2_EXECUTION_ENGINE_P2P=${port_l2_execution_engine_p2p}|" .env
    sed -i "s|PORT_PROVER_SERVER=.*|PORT_PROVER_SERVER=${port_prover_server}|" .env
    sed -i "s|PORT_PROMETHEUS=.*|PORT_PROMETHEUS=${port_prometheus}|" .env

    sudo systemctl restart babylond

}

# 卸载节点
function uninstall_node() {
    echo "确定要卸载Spectre节点吗？这将会删除所有相关的数据。[Y/N]"
    read -r -p "请确认: " response

    case "$response" in
        [yY][eE][sS]|[yY]) 
            echo "开始卸载节点..."
            cd $HOME
			sudo systemctl stop lava.service
			sudo systemctl disable lava.service
			sudo rm /etc/systemd/system/lava.service
			sudo systemctl daemon-reload
			rm -f $(which lavad)
			rm -rf $HOME/.lava
			rm -rf $HOME/lava
            echo "卸载完成。"
            ;;
        *)
            echo "取消卸载操作。"
            ;;
    esac
}

# 主菜单
function main_menu() {
    while true; do
        clear
        echo "===============Lava一键部署脚本==============="
	    echo "沟通电报群：https://t.me/lumaogogogo"
	    echo "最低配置：4C8G100G；推荐配置：4C16G500G"
        echo "1. 安装节点install node"
        echo "2. 创建钱包add wallet"
        echo "3. 导入钱包import wallet"
        echo "4. 创建验证者add validator"
        echo "5. 查看钱包地址余额check balances"
        echo "6. 查看节点同步状态check sync status"
        echo "7. 查看当前服务状态check service status"
        echo "8. 运行日志查询view logs"
        echo "9. 修改端口update ports"
        echo "10. 删除节点 uninstall_node"
        echo "0. 退出脚本exit"
        read -r -p "请输入选项: " OPTION
    
        case $OPTION in
        1) install_node ;;
        2) add_wallet ;;
        3) import_wallet ;;
        4) add_validator ;;
        5) check_balances ;;
        6) check_sync_status ;;
        7) check_service_status ;;
        8) view_logs ;;
        9) update_ports ;;
        10) uninstall_node ;;
        0) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项，请重新输入。"; sleep 3 ;;
        esac
        echo "按任意键返回主菜单..."
        read -n 1
    done
}

# 显示主菜单
main_menu