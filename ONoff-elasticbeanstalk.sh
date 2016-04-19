#!/bin/bash
# MAINTAINER Idioter <wholanda@yahoo.com>
set -x
# WARNING THIS CAN WORK IN VERSION BELOW:	
# aws-cli version = 1.10.14 
# Python version = 2.7.6
# Note: $1 inside a function indicates function parameter
# NOTE:
# script to restart sidekiq process, you can see example of development(/home/ubuntu/scripts/myapp-sidekiq-development) in this repo, adjust for sidekiq of staging
# systemdev is toy for devops & infra
# you may want to remove elastic ip or public ip, but you have to change alitle of this scripts
## REQUIREMENTS ##
# run in ec2 server with iam role attached
export JAVA_HOME="/usr/lib/jvm/java-1.8.0-openjdk-amd64"
export EC2_REGION=ap-southeast-1
export AWS_RDS_HOME=/usr/local/aws
export PATH=$PATH:$AWS_RDS_HOME/bin
AppName=$1
EnvName=$1
EnvironmentId=$(aws elasticbeanstalk describe-environments --environment-name $EnvName --output json|grep EnvironmentId|awk '{ print$2 }'|sed 's|[",]||g')
now=$(date +%Y%m%d)
nowrdsformat=$(date +%Y-%m-%d-%H%M)
yesterday=$(date +%Y%m%d --date="1 day ago")
#Decide the instance type
case "$EnvName" in
myapp-development)
        SidekiqInstanceType=t2.micro
        RdsInstanceType=db.t2.micro
        SidekiqKeyname=myapp-sidekiq-development
        SidekiqSecGroupId=your_Sidekiq_security_group_id
        RdsSecGroupId=your_rds_security_group_id
        SidekiqAllId=your_Sidekiq_elastic_ip_id_of_dev
        IpSidekiqDev=Public_ipaddress_of_sidekiq_dev
        Branch=develop
        IpSidekiq=$IpSidekiqDev
        DbSnapshotIdentifier=dbdevelopment-$nowrdsformat
        DbInstanceIdentifier=dbdevelopment
        TagName=myapp-sidekiq-development
      ;;
myapp-staging)
        SidekiqInstanceType=t2.medium
        RdsInstanceType=db.t2.small
        SidekiqKeyname=myapp-sidekiq-stage
        SidekiqSecGroupId=your_Sidekiq_security_group_id
        RdsSecGroupId=your_rds_security_group_id
        SidekiqAllId=your_Sidekiq_elastic_ip_id_of_staging
        IpSidekiqStg=Public_ipaddress_of_sidekiq_staging
        Branch=master
        IpSidekiq=$IpSidekiqStg
        DbSnapshotIdentifier=dbstaging-$nowrdsformat
        DbInstanceIdentifier=dbstaging
        TagName=myapp-sidekiq-staging
      ;;
myapp-systemdev)
        SidekiqInstanceType=t2.micro
        RdsInstanceType=db.t2.micro
        SidekiqKeyname=myapp-ami.pem
        SidekiqSecGroupId=your_Sidekiq_security_group_id
        RdsSecGroupId=your_rds_security_group_id
        SidekiqAllId=your_Sidekiq_elastic_ip_id_of_systemdev
        IpSidekiqSdev=Public_ipaddress_of_sidekiq_systemdev
        Branch=develop
        IpSidekiq=$IpSidekiqSdev
        DbSnapshotIdentifier=dbsystemdev-$nowrdsformat
        DbInstanceIdentifier=dbsystemdev
        TagName=myapp-sidekiq-development
      ;;
esac
#
#
Instruction() {
  echo "ERROR: "$1
  echo
  echo "usage:"
  echo "/etc/init.d/elasticb {application name} {start|stop}"
  echo
  echo "application name: e.g. myapp-staging & myapp-development"
  exit
}
#
#
# C H E C K I N G    P R O C E S S 
#
#
CheckAppName() {
aws elasticbeanstalk describe-applications --application-names $AppName --output text
}
#
#
CheckEnvName() {
aws elasticbeanstalk describe-environments --environment-name $EnvName --output text
}
#
CheckSidekiq() {
aws ec2 describe-instances --filters "Name=tag-value,Values=$EnvName-sidekiq" --output text|grep STATE|grep -v REASON|awk '{ print$3 }'i > /tmp/checksidekiq.txt
CheckSidekiqRunning=$(cat /tmp/checksidekiq.txt|grep running|tail -1)
CheckSidekiqRebooting=$(cat /tmp/checksidekiq.txt|grep rebooting|tail -1)
CheckSidekiqPending=$(cat /tmp/checksidekiq.txt|grep pending|tail -1)
}
#
#
CheckRds() {
aws rds describe-db-instances --db-instance-identifier $DbInstanceIdentifier --output text|head -1|sed "s|^.*$DbInstanceIdentifier|$DbInstanceIdentifier|g"|awk '{ print$2 }'
}
#
#
# C R E A T I N G    P R O C E S S
#
#
CreateAppName() {
#prepare repo
mkdir -p /var/app
git clone git@github.com:githubuserid/myrepo.git /var/app/myproject
#create application name
aws elasticbeanstalk create-application --application-name $AppName --description "This is $AppName"
#create folder to place file config in bucket of application
aws s3 sync s3://eb-myapp-backup/resources/templates/ s3://your_eb_bucket/resources/templates/
#compress repo and upload it
cd /var/app/myproject && git checkout $Branch && git pull origin $Branch && git archive --format=zip HEAD > /tmp/$AppName-$now.zip
aws s3 cp /tmp/$AppName-$now.zip s3://eb-myapp-backup/repo/$AppName/
}
#
#
CreateAppVersion() {
aws elasticbeanstalk create-application-version --application-name $AppName --version-label $AppName-$now --description "this is repo of $AppName-$now" --source-bundle S3Bucket="eb-myapp-backup",S3Key="repo/$AppName/$AppName-$now.zip" --auto-create-application
}
#
#
CreateEnvName() {
CreateAppVersion
LastEnvName=$(aws s3 ls s3://eb-myapp-backup/resources/templates/$EnvName/|awk '{ print$4 }'|sed "s|s3://eb-myapp-backup/resources/templates/$EnvName/||g"|tail -1)
aws elasticbeanstalk create-environment --cname-prefix $EnvName --application-name $AppName --template-name $LastEnvName --environment-name $EnvName --version-label $AppName-$now
}
#
#
CreateSidekiq() {
#Create user data file
cat <<EOF > /tmp/yuminfo.txt
#cloud-config
repo_releasever: $repo_release
repo_upgrade: none
EOF
# get latest ami id of sidekiq
LastSidekiqImage=$(aws ec2 describe-images --filters Name=name,Values=sidekiq-$EnvName-* --output text|grep IMAGES | sort -k3,3 -k3,4 -k3,6 -k3,7 -k3,9 -k3,10 -k3,12 -k3,13 -k3,15 -k3,16|tail -1|sed 's|^.*ami-|ami-|g'|awk '{ print$1 }')
#Create ec2 instance of sidekiq
aws ec2 run-instances \
--image-id $LastSidekiqImage \
--user-data file:///tmp/yuminfo.txt \
--count 1 \
--instance-type $SidekiqInstanceType \
--iam-instance-profile Name="aws-elasticbeanstalk-ec2-role" \
--key-name $SidekiqKeyname \
--security-group-ids $SidekiqSecGroupId \
--subnet-id YOUR_SUBNET_ID \
--associate-public-ip-address \
> /tmp/info-instance
#Get instance id of sidekiq
SidekiqInstanceId=$(cat /tmp/info-instance | grep InstanceId | awk '{ print$2 }'|sed 's|[",]||g')
#Waiting for ec2 status
SidekiqInstanceState=$(aws ec2 describe-instances --instance-id $SidekiqInstanceId --output text|grep STATE|awk '{ print$3 }')
while [ -z "$SidekiqInstanceState" -o "$SidekiqInstanceState" == "pending" ]
do
SidekiqInstanceState=$(aws ec2 describe-instances --instance-id $SidekiqInstanceId --output text|grep STATE|awk '{ print$3 }')
done
#Associate elastic ip address to sidekiq
aws ec2 associate-address --instance-id $SidekiqInstanceId --allocation-id $SidekiqAllId
#Rename tagname of instance
aws ec2 create-tags --resources $SidekiqInstanceId --tags Key=Name,Value=$EnvName-sidekiq
#wait for public ip attached
sleep 5
#get public ip address of this instance
public_ip=$(aws ec2 describe-instances --instance-ids $SidekiqInstanceId | grep PublicIpAddress -m 1 | awk '{print$2}' | sed 's|[",]||g')
#Remove local host key
ssh-keygen -f "/root/.ssh/known_hosts" -R $public_ip
echo "-----BEGIN RSA PRIVATE KEY----- your id rsa here -----END RSA PRIVATE KEY-----" > /tmp/id_rsa
chmod 600 /tmp/id_rsa
#Wait for ssh connection
check_ssh=$(ssh -q -i /tmp/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$public_ip exit; echo $?)
while [ $check_ssh -eq 255 ]
do
check_ssh=$(ssh -q -i /tmp/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$public_ip exit; echo $?)
done
#Run update repo & bundle install
case "$EnvName" in
myapp-staging)
        ssh ubuntu@$public_ip -i /tmp/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no 'bash -l -c "cd /home/ubuntu/myproject && /home/ubuntu/scripts/myapp-sidekiq-staging stop && git pull origin master && bundle install && sleep 8 && /home/ubuntu/scripts/myapp-sidekiq-staging start"'
        ;;
myapp-development)
        ssh ubuntu@$public_ip -i /tmp/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no 'bash -l -c "cd /home/ubuntu/myproject && /home/ubuntu/scripts/myapp-sidekiq-development stop && git pull origin develop && bundle install && sleep 8 && /home/ubuntu/scripts/myapp-sidekiq-development start"'
        ;;
myapp-systemdev)
ssh ubuntu@$public_ip -i /tmp/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no 'bash -l -c "cd /home/ubuntu/myproject && /home/ubuntu/scripts/myapp-sidekiq-development stop && git pull origin develop && bundle install && sleep 8 && /home/ubuntu/scripts/myapp-sidekiq-development start"'
        ;;
esac
}
#
#
StartRds() {
#find the last snapshot, make it as variable
TheLastSnapshot=$(aws rds describe-db-snapshots --output text|grep $DbInstanceIdentifier | grep -v rds:| sort -k9,3 -k9,4 -k9,6 -k9,7 -k9,9 -k9,10 -k9,12 -k9,13 -k9,15 -k9,16|tail -1|sed "s|^.*$DbInstanceIdentifier-|$DbInstanceIdentifier-|g"|awk '{ print$1 }')
#restore from latest snapshot
RdsStatus=$(aws rds describe-db-instances --db-instance-identifier $DbInstanceIdentifier --output text|head -1|sed "s|^.*$DbInstanceIdentifier|$DbInstanceIdentifier|g"|awk '{ print$2 }')
while [ "$RdsStatus" == "deleting" ]
do
RdsStatus=$(aws rds describe-db-instances --db-instance-identifier $DbInstanceIdentifier --output text|head -1|sed "s|^.*$DbInstanceIdentifier|$DbInstanceIdentifier|g"|awk '{ print$2 }')
done
aws rds restore-db-instance-from-db-snapshot --db-instance-identifier $DbInstanceIdentifier --db-snapshot-identifier $TheLastSnapshot --db-instance-class $RdsInstanceType --port 5432 --availability-zone ap-southeast-1a --db-subnet-group-name myapp-network-rds --no-multi-az --publicly-accessible --auto-minor-version-upgrade --storage-type gp2
while [ -z "$RdsStatus" -o "$RdsStatus" != "available" ]
do
RdsStatus=$(aws rds describe-db-instances --db-instance-identifier $DbInstanceIdentifier --output text|head -1|sed "s|^.*$DbInstanceIdentifier|$DbInstanceIdentifier|g"|awk '{ print$2 }')
done
#Change Security Group of RDS
aws rds modify-db-instance --db-instance-identifier $DbInstanceIdentifier --vpc-security-group-ids $RdsSecGroupId
}
#
#
# S T O P I N G   P R O C E S S
#
#
TerminateEnvName() {
#backup config
aws elasticbeanstalk create-configuration-template --environment-id $EnvironmentId --application-name $AppName --template-name $AppName-$now
#backup config to  backup folder
aws s3 sync s3://YOUR_EB_BUCKET/resources/templates/ s3://eb-myapp-backup/resources/templates/
#terminate Environment
aws elasticbeanstalk terminate-environment --environment-name $EnvName
}
#
#
TerminateAppName() {
#delete application name & env
aws elasticbeanstalk delete-application --application-name $AppName
}
#
#
TerminateSidekiq() {
#Get instance id of sidekiq
SidekiqInstanceId=$(aws ec2 describe-instances --filters "Name=ip-address,Values=$IpSidekiq" --output text | grep INSTANCES|awk '{ print$8 }')
#snapshot current sidekiq
aws ec2 create-image --instance-id $SidekiqInstanceId --name "sidekiq-$EnvName-$now" --description "An AMI for $EnvName"
#waiting snapshot process
SidekiqSnapshotStatus=$(aws ec2 describe-images --filters Name=name,Values=sidekiq-$EnvName-$now --output text|sed 's|^.*ebs||g'|head -1|awk '{ print$2 }')
while [ "$SidekiqSnapshotStatus" != "available" ]
do
SidekiqSnapshotStatus=$(aws ec2 describe-images --filters Name=name,Values=sidekiq-$EnvName-$now --output text|sed 's|^.*ebs||g'|head -1|awk '{ print$2 }')
done
#disable termination protection
aws ec2 modify-instance-attribute --instance-id $SidekiqInstanceId --disable-api-termination "{\"Value\": false}"
#terminate sidekiq
aws ec2 terminate-instances --instance-ids $SidekiqInstanceId
}
#
#
TerminateRds() {
#snapshot rds
aws rds create-db-snapshot --db-snapshot-identifier $DbSnapshotIdentifier --db-instance-identifier $DbInstanceIdentifier 
#Wait snapshot rds finish
CheckRdsSnapshot=$(aws rds describe-db-snapshots --db-snapshot-identifier $DbSnapshotIdentifier --output text|sed 's|^.*manual||g'|awk '{ print$1 }')
while [ "$CheckRdsSnapshot" != "available" ]
do
CheckRdsSnapshot=$(aws rds describe-db-snapshots --db-snapshot-identifier $DbSnapshotIdentifier --output text|sed 's|^.*manual||g'|awk '{ print$1 }')
done
#Terminate rds instance
aws rds delete-db-instance --db-instance-identifier $DbInstanceIdentifier --skip-final-snapshot
}
#
#
stop() {
if [ -z "$AppName" -o "$AppName" = myapp-production ]; then
  Instruction "application name is required & myapp-production is not allowed"
else
  if [ -z "$(CheckAppName)" ]; then
    echo "Application is already terminated"
  else
    if [ -z "$(CheckEnvName)" ]; then
      echo "Environment is already terminated"
    else
      TerminateEnvName
      TerminateAppName
    fi
  fi
  if [ "$(CheckSidekiq)" != "running" ]; then
    echo "Sidekiq is already terminated"
  else
    TerminateSidekiq
  fi
  if [ -z "$(CheckRds)" ]; then
    echo "Rds is already terminated"
  else
    TerminateRds
  fi
fi
}
#
#
start() {
#Start date
echo -e "Start at $(date)"
if [ -z "$AppName"  -o "$AppName" = myapp-production ]; then
  Instruction "application name is required"
else
  if [ -z "$(CheckRds)" ]; then
    StartRds
  fi
  if [ -z "$(CheckAppName)" ]; then
    CreateAppName
  fi
  if [ -z "$(CheckEnvName)" ]; then
    CreateEnvName
  fi
  CheckSidekiq
  if [ "$CheckSidekiqRunning" == "running" ] || [ "$CheckSidekiqRebooting" == "rebooting" ] || [ "$CheckSidekiqPending" == "pending" ]; then
    echo "sidekiq is already there"
  else
    CreateSidekiq
  fi
fi
#End date
echo -e "End at $(date)"
}
#
#
case "$2" in
  start)
      start
    ;;
  stop)
      stop
    ;;
  *)
    echo "Usage: /etc/init.d/elasticb {application name} {start|stop}"
    exit 1
    ;;
esac

exit 0
