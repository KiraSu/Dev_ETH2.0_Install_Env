#!/bin/bash

ARCHI=$(uname -m)
NETWORK=goerli
EC2_Info=
INSTANCE_TYPE=c7g.large
RUN_DIR=$(pwd)
LIGHTHOUSE_CONFIG_JSON=
GETH_ENDPOINT=
GETH_JWT_SECRECT=
declare -l MetaModuleName=
ModuleRunCMD=
RemoteEC2Result=
BEACON_NODE_CHECKPOINT_URL="https://goerli.checkpoint-sync.ethdevops.io"
RES_TAG_ATTR=("ResourceType=instance,Tags=[{Key=Name,Value=TestETH2.0_Geth_${NETWORK}}]" "ResourceType=instance,Tags=[{Key=Name,Value=TestETH2.0_Lighthouse_${NETWORK}}]")
EBS_JSON="[\
    {\
        \"DeviceName\": \"/dev/xvda\",\
        \"Ebs\": {\
            \"VolumeType\": \"gp3\",\
            \"VolumeSize\": 64\
        }\
    },\
    {\
	\"DeviceName\": \"/dev/sdf\",\
        \"Ebs\": {\
            \"VolumeType\": \"gp3\",\
            \"VolumeSize\": 256\
        }\
    }\
]"
CMAKE_VERSION=3.24.1
GETH_TAG_VERSION=v1.10.23

create_ec2_instance() {
    echo $EBS_JSON > $RUN_DIR/ebs_mapping.json
    RemoteEC2Result=$(aws ec2 run-instances --no-cli-page --image-id $(echo $EC2_Info | jq -r '.[0].ImageId') --count 1 --instance-type $1 --key-name $(echo $EC2_Info | jq -r '.[0].KeyName') --security-group-ids $(echo $EC2_Info | jq -r '.[0].GroupId') --subnet-id $(echo $EC2_Info | jq -r '.[0].SubnetId') --associate-public-ip-address --block-device-mappings file://$RUN_DIR/ebs_mapping.json --tag-specifications $2)
    echo "RemoteEC2Result: $RemoteEC2Result"
    if [ $? -ne 0 ]; then
        echo "create_ec2_instance failed: $RemoteEC2Result"
	exit 0
    fi
    
    EC2InstanceId=$(echo $RemoteEC2Result | jq -r '.Instances[0].InstanceId')
    echo "Waiting EC2[$EC2InstanceId] status running..."
    EC2WaitRunning=$(aws ec2 wait instance-running --instance-ids $EC2InstanceId)
    sleep 5s
}

sudo yum update -y
sudo yum install -y git gcc g++ make pkg-config llvm-dev libclang-dev clang openssl-devel go jq

###### Install AWS Cli
if command -v aws &> /dev/null
then
    ###### aws-cli/2.7.31 Python/3.9.11 Linux/5.10.130-118.517.amzn2.aarch64 exe/aarch64.amzn.2 prompt/off
    if [ $(which aws) = "/usr/bin/aws" ]; then
	echo "Upgrade AWS Cli..."
        cd $HOME && curl "https://awscli.amazonaws.com/awscli-exe-linux-$ARCHI.zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install
        rm -r aws && rm awscliv2.zip
    fi
else
    echo "Install AWS Cli...."
    cd $HOME && curl "https://awscli.amazonaws.com/awscli-exe-linux-$ARCHI.zip" -o "awscliv2.zip" && unzip awscliv2.zip && sudo ./aws/install
    rm -r aws && rm awscliv2.zip
fi

###### Check cmake
if ! command -v cmake &> /dev/null
then
    cd $HOME
    wget https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION.tar.gz
    tar -zxf cmake-$CMAKE_VERSION.tar.gz && cd cmake-$CMAKE_VERSION && ./bootstrap && make -j8 && sudo make install
    cd $HOME && sudo rm -r cmake-$CMAKE_VERSION && sudo rm cmake-$CMAKE_VERSION.tar.gz
fi

###### Get this ec2 instance info
EC2_InfoCMD=$(echo "aws ec2 describe-instances --no-cli-page --query 'Reservations[*].Instances[?contains(InstanceId,\`$(curl http://169.254.169.254/latest/meta-data/instance-id)\`)]|[].{InstanceType:InstanceType,InstanceId:InstanceId,ImageId:ImageId,KeyName:KeyName,AvailabilityZone:Placement.AvailabilityZone,VpcId:VpcId,SubnetId:SubnetId,GroupId:NetworkInterfaces[0].Groups[0].GroupId}'")
echo $EC2_InfoCMD
EC2_Info=$(eval $EC2_InfoCMD)
if [ $? -ne 0 ]; then
    echo "Get EC2 Info failed."
    echo "EC2_Info: ${EC2_Info}"
    exit 0
fi
echo "EC2_Info: ${EC2_Info}"

####### Build geth
if [ ! -d "$HOME/go-ethereum" ]; then
    cd $HOME && git clone https://github.com/ethereum/go-ethereum.git
fi
cd $HOME/go-ethereum && git checkout $GETH_TAG_VERSION && make all -j8

###### Build lighthouse
if [ ! -d "$HOME/lighthouse" ]; then
    cd $HOME && git clone https://github.com/sigp/lighthouse.git
fi
cd $HOME/lighthouse && git checkout stable && make -j8

for tagValue in ${RES_TAG_ATTR[@]}
do
MetaModuleName=$(echo "$tagValue" | cut -d '_' -f 2)
###### Create Geth/Lighthouse EC2 Instance if not exist [geth(lighthouse)_ec2_instance.json] otherwise load the [geth(lighthouse)_ec2_instance.json] file to upgrade geth service
if [ ! -f "$HOME/${MetaModuleName}_ec2_instance.json" ]; then
    ###### Call create EC2 instance
    create_ec2_instance $INSTANCE_TYPE $tagValue
    echo $RemoteEC2Result > $HOME/${MetaModuleName}_ec2_instance.json
    
    RemoteEC2IpAddr="$(echo $RemoteEC2Result | jq -r '.Instances[0].PrivateIpAddress')"
    RemoteSSH="ssh -i $RUN_DIR/key.pem ec2-user@$RemoteEC2IpAddr"
    
    ###### Init the extend disk
    RemoteCMDExe="$RemoteSSH 'sudo yum update -y && sudo mkdir -p /var/lib/${MetaModuleName} && sudo pvcreate /dev/nvme1n1 && sudo vgcreate vg_default /dev/sdf && sudo lvcreate -l 100%VG -n lv_data vg_default && sudo mkfs.ext4 /dev/vg_default/lv_data && sudo mount -t ext4 /dev/vg_default/lv_data /var/lib/${MetaModuleName} && echo \"/dev/mapper/vg_default-lv_data /var/lib/${MetaModuleName} ext4 defaults 0 0\" | sudo tee -a /etc/fstab'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe

    if [[ -z $GETH_JWT_SECRECT ]]; then
        ModuleRunCMD="/usr/local/bin/${MetaModuleName} --${NETWORK} --http --http.addr 0.0.0.0 --authrpc.addr 0.0.0.0 --datadir /var/lib/${MetaModuleName}/.${MetaModuleName}/${NETWORK}"
    else
        ModuleRunCMD="/usr/local/bin/${MetaModuleName} -d /var/lib/${MetaModuleName}/.${MetaModuleName}/${NETWORK} --network ${NETWORK} bn --checkpoint-sync-url=$BEACON_NODE_CHECKPOINT_URL --http --execution-endpoint http://$GETH_ENDPOINT --execution-jwt /var/lib/${MetaModuleName}/.${MetaModuleName}/${NETWORK}/jwtsecret"
	RemoteCMDExe="$RemoteSSH 'sudo mkdir -p /var/lib/${MetaModuleName}/.${MetaModuleName}/${NETWORK} && echo $GETH_JWT_SECRECT | sudo tee /var/lib/${MetaModuleName}/.${MetaModuleName}/${NETWORK}/jwtsecret > /dev/null'"
	echo $RemoteCMDExe
	eval $RemoteCMDExe
    fi
    
    ###### Add 'geth/lighthouse' user
    RemoteCMDExe="$RemoteSSH 'if [ id \"${MetaModuleName}\" &>/dev/null ]; then echo ok; else sudo useradd --no-create-home --shell /bin/false ${MetaModuleName}; fi'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe
    
    ###### Change /var/lib/geth or /var/lib/lighthouse directory owner
    RemoteCMDExe="$RemoteSSH 'sudo chown -R ${MetaModuleName}:${MetaModuleName} /var/lib/${MetaModuleName}'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe
    
    ###### Create service config file
    RemoteCMDExe="$RemoteSSH 'echo -e [Unit]\\\\nDescription=${MetaModuleName} Execution Client\\\\nWants=network.target\\\\nAfter=network.target\\\\n\\\\n[Service]\\\\nUser=${MetaModuleName}\\\\nGroup=${MetaModuleName}\\\\nType=simple\\\\nRestart=always\\\\nRestartSec=5\\\\nExecStart=${ModuleRunCMD}\\\\n\\\\n[Install]\\\\nWantedBy=default.target\\\\n | sudo tee /etc/systemd/system/${MetaModuleName}.service > /dev/null'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe
else
    RemoteEC2Result=$(cat $HOME/${MetaModuleName}_ec2_instance.json)
    RemoteEC2IpAddr="$(echo $RemoteEC2Result | jq -r '.Instances[0].PrivateIpAddress')"
    RemoteSSH="ssh -i $RUN_DIR/key.pem ec2-user@$RemoteEC2IpAddr"
fi

###### Stop geth/lighthouse service
RemoteCMDExe="$RemoteSSH 'while systemctl is-active ${MetaModuleName} &>/dev/null ;do sudo systemctl stop ${MetaModuleName} && sleep 3s;done'"
echo $RemoteCMDExe
eval $RemoteCMDExe

###### Copy all Geth/Lighthouse bin file to remote ec2 /usr/local/bin
RemoteCMDExe="$RemoteSSH '[ -d $HOME/${MetaModuleName} ] && echo ok || mkdir -p $HOME/${MetaModuleName}'"
echo $RemoteCMDExe
eval $RemoteCMDExe
if [ $? -eq 0 ]; then
    RemoteCMDExe="scp -i $RUN_DIR/key.pem $HOME/go-ethereum/build/bin/* ec2-user@$RemoteEC2IpAddr:~/${MetaModuleName}"
    echo $RemoteCMDExe
    eval $RemoteCMDExe
    
    RemoteCMDExe="$RemoteSSH 'sudo cp ~/${MetaModuleName}/* /usr/local/bin'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe
    
    RemoteCMDExe="$RemoteSSH 'sudo systemctl daemon-reload && sudo systemctl start ${MetaModuleName} && sudo systemctl status ${MetaModuleName}'"
    echo $RemoteCMDExe
    eval $RemoteCMDExe

    if [[ -z $GETH_JWT_SECRECT ]]; then
	echo "Waiting $MetaModuleName service start..."
        sleep 5s
        RemoteCMDExe="$RemoteSSH 'cat /var/lib/${MetaModuleName}/.${MetaModuleName}/${NETWORK}/${MetaModuleName}/jwtsecret'"
	echo $RemoteCMDExe
	GETH_JWT_SECRECT=$(eval $RemoteCMDExe)
	GETH_ENDPOINT="$RemoteEC2IpAddr:8551"
    fi
fi

done

<<'COMMENT'
#Create Lighthouse Instance if not exist [lighthouse_ec2_instance.json] otherwise load the [lighthouse_ec2_instance.json] file to upgrade lighthouse service
if [ ! -f "$HOME/lighthouse_ec2_instance.json" ]; then
    #Call create geth ec2 instance
    create_ec2_instance $INSTANCE_TYPE $LighthouseResTagAttr
    echo $? > $HOME/lighthouse_ec2_instance.json
fi
LIGHTHOUSE_EC2_INFO=$(cat $HOME/lighthouse_ec2_instance.json)
LighthouseRemoteEC2IpAddr="$(echo $LIGHTHOUSE_EC2_INFO | jq -r '.Instances[0].PrivateIpAddress')"
LighthouseRemoteSSH="ssh -i $RUN_DIR/key.pem ec2-user@$LighthouseRemoteEC2IpAddr"


#EBS config output to file
echo $EBS_JSON > $RUN_DIR/ebs_mapping.json
#Create ec2 instance
for tagValue in ${ResTagArr[@]}
do
    #$(echo $EC2_Info | jq -r '.[0].InstanceType')
    EC2Result=$(aws ec2 run-instances --no-cli-page --image-id $(echo $EC2_Info | jq -r '.[0].ImageId') --count 1 --instance-type $INSTANCE_TYPE --key-name $(echo $EC2_Info | jq -r '.[0].KeyName') --security-group-ids $(echo $EC2_Info | jq -r '.[0].GroupId') --subnet-id $(echo $EC2_Info | jq -r '.[0].SubnetId') --associate-public-ip-address --block-device-mappings file://$RUN_DIR/ebs_mapping.json --tag-specifications $tagValue)
    
    echo $EC2Result
    EC2InstanId=$(echo $EC2Result | jq -r '.Instances[0].InstanceId')
    EC2WaitStateRunning=$(aws ec2 wait instance-running --instance-ids $EC2InstanId)
    sleep 5s
    
    RemoteEC2Hostname=$(echo $EC2Result | jq -r '.Instances[0].Tags[0].Value')
    RemoteEC2IpAddr="$(echo $EC2Result | jq -r '.Instances[0].PrivateIpAddress')"
    RemoteSSHEC2Info="ec2-user@$RemoteEC2IpAddr"

    CMDModifyRemoteEC2HostName="ssh -i $RUN_DIR/key.pem $RemoteSSHEC2Info 'sudo hostnamectl --static set-hostname '$RemoteEC2Hostname''"
    echo "CMDModifyRemoteEC2HostName: $CMDModifyRemoteEC2HostName"
    eval $CMDModifyRemoteEC2HostName
    if [ $? -ne 0 ]; then
        sleep 5s
	eval $CMDModifyRemoteEC2HostName
	if [ $? -ne 0 ]; then
            echo "RemoteExecute[$CMDModifyRemoteEC2HostName] Failed. Try terminate this[$EC2InstanId] EC2 instance..."
	    aws ec2 terminate-instances --instance-ids $EC2InstanId
	    exit 0
	fi
    fi

    CMDCopyInstallScript="scp -i $RUN_DIR/key.pem ./Install.sh $RemoteSSHEC2Info:~"
    echo "CMDCopyInstallScript: $CMDCopyInstallScript"
    eval $CMDCopyInstallScript
    if [ $? -ne 0 ]; then
        echo "RemoteExecute[$CMDCopyInstallScript] Failed. Try terminate this[$EC2InstanId] EC2 instance..."
        aws ec2 terminate-instances --instance-ids $EC2InstanId
        exit 0
    fi
    
    ConfigData="{\"NETWORK\": \"$NETWORK\"}"
    CMDCopyInstallConfigJson="scp -i $RUN_DIR/key.pem ./config.json $RemoteSSHEC2Info:~"
    if [[ ! -z $LIGHTHOUSE_CONFIG_JSON ]]; then
        ConfigData=$LIGHTHOUSE_CONFIG_JSON
    fi
    echo "$ConfigData" > config.json
    echo "CMDCopyInstallConfigJson: $CMDCopyInstallConfigJson"
    eval $CMDCopyInstallConfigJson
    if [ $? -ne 0 ]; then
        echo "RemoteExecute[$CMDCopyInstallConfigJson] Failed. Try terminate this[$EC2InstanId] EC2 instance..."
        aws ec2 terminate-instances --instance-ids $EC2InstanId
        exit 0
    fi
    
    CMDExeScript="ssh -i $RUN_DIR/key.pem $RemoteSSHEC2Info '~/Install.sh'"
    echo $CMDExeScript
    eval $CMDExeScript
    if [ $? -ne 0 ]; then
        echo "RemoteExecute[$CMDExeScript] Failed. Try terminate this[$EC2InstanId] EC2 instance..."
        aws ec2 terminate-instances --instance-ids $EC2InstanId
        exit 0
    fi
    
    if [[ $RemoteEC2Hostname == *"geth"* ]]; then
	echo "Waiting $RemoteEC2Hostname service startup..."
	sleep 5s
	
	CMDGetJWTSecret="ssh -i $RUN_DIR/key.pem $RemoteSSHEC2Info 'sudo cat /var/lib/geth/.ethereum/goerli/geth/jwtsecret'"
	EXECUTION_JWTSECRET=$(eval $CMDGetJWTSecret)
	if [ $? -ne 0 ]; then
	    echo "Get[$CMDGetJWTSecret] EXECUTION_JWTSECRET failed."
	    exit 0
	fi
	LIGHTHOUSE_CONFIG_JSON="{\"NETWORK\": \"$NETWORK\", \"BEACON_NODE_CHECKPOINT_URL\": \"$BEACON_NODE_CHECKPOINT_URL\", \"EXECUTION_ENDPOINT\": \"$RemoteEC2IpAddr\", \"EXECUTION_JWTSECRET\": \"$EXECUTION_JWTSECRET\"}"
	echo "LIGHTHOUSE_CONFIG_JSON: $LIGHTHOUSE_CONFIG_JSON"
    fi
done
COMMENT
