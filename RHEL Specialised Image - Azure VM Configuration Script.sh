# This script is a mixture of the MS guidance, the Red Hat guidance plus some other elemets from research whislt troubleshooting SSH and Serial connectivity issues for a specialised Linux VM.
# It was tested using a Hyper-v server running in Azure with nested virtualisation then converted to a static .vhd and then uploaded to an Azure storage acccount
# where a managed disk was created & gen 2 vM was created.
#
# Created by David Rowley - david.rowley@ibm.com
# Sources used
#  1. https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/deploying_rhel_9_on_microsoft_azure/index#making-configuration-changes_configure-the-image-azure
#  2. https://learn.microsoft.com/en-us/azure/virtual-machines/linux/redhat-create-upload-vhd?tabs=rhel7hv
#  3. https://access.redhat.com/solutions/7024710
#  4. https://github.com/Azure/WALinuxAgent?tab=readme-ov-file#extensionswaitforcloudinit
#  5. Kernel boot parameters - Taken from an Azure Gallery RHEL image
#
# ***Do your own due dilligence as guidance is regulary updated.  This is provided as-is, no warrantee is implied or otherwise, use at your own risk.***

# Output to console and to the AzureVMSetup.log logfile in your current location
set -x
exec > >(tee -a AzureVMSetup.log) 2>&1

#check networking is up
sudo systemctl start NetworkManager
sudo systemctl enable NetworkManager

#Pick either a static IP address or make sure DHCP is configured
#Static-IP
#sudo nmcli connection modify eth0 ipv4.addresses 192.168.100.130/24 ipv4.gateway 192.168.100.1 ipv4.dns "8.8.8.8, 8.8.4.4" ipv4.method manual && sudo nmcli connection up eth0

#DHCP
sudo nmcli con mod eth0 connection.autoconnect yes ipv4.method auto

#connect to redhat - you can set your details here,  it will request the username/password details, you can
#include them here but that's bad, never, ever include passwords in scripts
sudo subscription-manager register --auto-attach

#Install Mellanox Drivers as Azure uses these in some instances 
sudo dnf install -y mstflint

#Install Required System Packages https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/deploying_rhel_9_on_microsoft_azure/index#required-system-packages_understanding-base-images-azure
#Not 100% sure if these are needed as probably targeted at a Linux Host building a guest, and probably safe to remove, one for another day.
sudo subscription-manager repos --enable rhel-9-for-x86_64-appstream-rpms
sudo dnf install -y libvirt virt-install libguestfs guestfs-tools

#Install the Windows Azure Linux Agent, Hyper-V device drivers  plus other dependencies & enable
sudo dnf install -y WALinuxAgent cloud-init cloud-utils-growpart gdisk hyperv-daemons
sudo systemctl enable waagent.service
sudo systemctl enable cloud-init.service
sudo systemctl enable waagent

# Create/Edit the hv.conf file
sudo tee /etc/dracut.conf.d/hv.conf > /dev/null <<EOF 
add_drivers+=" hv_vmbus "
add_drivers+=" hv_netvsc "
add_drivers+=" hv_storvsc "
add_drivers+=" nvme "
EOF

#Regenerate the initramfs image-azure
sudo dracut -f -v --regenerate-all

#check to see if the 10-azure-kvp.cfg and 91-azure_datasource.cfg files exist, if not create them
sudo touch /etc/cloud/cloud.cfg.d/10-azure-kvp.cfg
sudo touch /etc/cloud/cloud.cfg.d/91-azure_datasource.cfg

#Configure Mounts
sudo echo "Adding mounts and disk_setup to init stage"
sudo sed -i '/ - mounts/d' /etc/cloud/cloud.cfg
sudo sed -i '/ - disk_setup/d' /etc/cloud/cloud.cfg
sudo sed -i '/cloud_init_modules/a\\ - mounts' /etc/cloud/cloud.cfg
sudo sed -i '/cloud_init_modules/a\\ - disk_setup' /etc/cloud/cloud.cfg

#setup telemetry collection for Azure
#enable logging to the Hyper-V data Exchange SErvice (KVP)
sudo tee /etc/cloud/cloud.cfg.d/10-azure-kvp.cfg > /dev/null <<EOF
reporting:
    logging:
        type: log
    telemetry:
        type: hyperv
EOF

#add Azure as a datasource
sudo tee /etc/cloud/cloud.cfg.d/91-azure_datasource.cfg > /dev/null <<EOF 
datasource_list: 
   [ Azure ]
datasource:
   Azure:
     apply_network_config: False
EOF

#Block specific modules from loading automatically
#create the file if it doesn't exist already
sudo touch /etc/modprobe.d/blocklist.confg
#Make the changes
sudo tee /etc/modprobe.d/blocklist.conf > /dev/null <<EOF 
blacklist nouveau
blacklist lbm-nouveau
blacklist floppy
blacklist amdgpu
blacklist skx_edac
blacklist intel_cstate
EOF

#Modify udev network device rules to remove these persistent network device rules, if present
sudo rm -f /etc/udev/rules.d/70-persistent-net.rules
sudo rm -f /etc/udev/rules.d/75-persistent-net-generator.rules
sudo rm -f /etc/udev/rules.d/80-net-name-slot-rules

#Create a new network device rule to ensure Accelerated Networking on Azure works as expected
# Accelerated Networking on Azure exposes a new SRIOV interface to the VM.
# This interface is transparently bonded to the synthetic interface,
# so NetworkManager should just ignore any SRIOV interfaces.
sudo tee /etc/udev/rules.d/68-azure-sriov-nm-unmanaged.rules > /dev/null <<EOF 
SUBSYSTEM=="net", DRIVERS=="hv_pci", ACTION!="remove", ENV{NM_UNMANAGED}="1"
EOF

#Set sshd service to start automatically
sudo systemctl enable sshd
sudo systemctl is-enabled sshd

#make sure SSH timeout is correct, this gets appended to the existing file
sudo tee -a /etc/ssh/sshd_config > /dev/null <<EOF 
ClientAliveInterval 180
EOF

#remove current GRUB parameters
sudo grub2-editenv - unset kernelopts

#modify kernel boot parameters, this will replace the contents of the current file
sudo tee /etc/default/grub > /dev/null <<EOF 
GRUB_TIMEOUT=10
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX="loglevel=3 crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M console=tty1 console=ttyS0,115200n8 earlyprintk=ttyS0,115200 net.ifnames=0"
GRUB_DISABLE_RECOVERY="true"
GRUB_ENABLE_BLSCFG=true
GRUB_TIMEOUT_STYLE=countdown
GRUB_TERMINAL="serial console"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF

#regenerate the grub.cfg file for this we are targeting UEFI (Gen2 VMs).
#target RHEL 9.3 and later.  Note that this differs from the MS article, this is from the red-hat site where BIOS & UEFI (GEN1/GEN2) are the same command
sudo grub2-mkconfig -o /boot/grub2/grub.cfg --update-bls-cmdline


#edit the waagent.conf file, as this specialised image already has a root password that we want to persist, so we are not resetting here
#1: Do not delete root password
#2: Do not regenerate SSH key pairs
#3: Set the provisioning agent to use cloud-init
#4: As we have a custom image, make sure we wait for cloud-init to complete before executing VM extenstions so we don't see any conficts.
#5: ensure we eon't format
#6: disable the swap partition
#7: Set the SSH client alive interval to 180
sudo sed -i 's/Provisioning.DeleteRootPassword=y/Provisioning.DeleteRootPassword=n/g' /etc/waagent.conf
sudo sed -i 's/Provisioning.RegenerateSshHostKeyPair=y/Provisioning.RegenerateSshHostKeyPair=n/g' /etc/waagent.conf
sudo sed -i 's/Provisioning.Agent=auto/Provisioning.Agent=cloud-init/g' /etc/waagent.conf 
sudo sed -i 's/Extensions.WaitForCloudInit=n/Extensions.WaitForCloudInit=y/g' /etc/waagent.conf
sudo sed -i 's/ResourceDisk.Format=y/ResourceDisk.Format=n/g' /etc/waagent.conf
sudo sed -i 's/ResourceDisk.EnableSwap=y/ResourceDisk.EnableSwap=n/g' /etc/waagent.conf
sudo sed -i 's/^#\?OS.SshClientAliveInterval=.*/OS.SshClientAliveInterval=180/g' /etc/waagent.conf

#if configured, remove the existing swap file:
if [[ -f /mnt/resource/swapfile ]]; then
echo "Removing swapfile" #RHEL uses a swapfile by default, we don't want this on Azure
sudo swapoff /mnt/resource/swapfile
sudo rm /mnt/resource/swapfile -f
fi

#confgure cloud-init logging:
# This tells cloud-init to redirect its stdout and stderr to
# 'tee -a /var/log/cloud-init-output.log' so the user can see output
# there without needing to look on the console.
sudo echo "Add console log file"
sudo tee /etc/cloud/cloud.cfg.d/05_logging.cfg > /dev/null <<EOF
output: {all: '| tee -a /var/log/cloud-init-output.log'}
EOF

#use a cloud-init directive to ensure the correct swapfile configuration
sudo echo 'DefaultEnvironment="CLOUD_CFG=/etc/cloud/cloud.cfg.d/00-azure-swap.cfg"' >> /etc/systemd/system.conf
sudo tee  /etc/cloud/cloud.cfg.d/00-azure-swap.cfg << EOF
#cloud-config
# Generated by Azure cloud image build
disk_setup:
  ephemeral0:
    table_type: mbr
    layout: [66, [33, 82]]
    overwrite: True
fs_setup:
  - device: ephemeral0.1
    filesystem: ext4
  - device: ephemeral0.2
    filesystem: swap
mounts:
  - ["ephemeral0.1", "/mnt/resource"]
  - ["ephemeral0.2", "none", "swap", "sw,nofail,x-systemd.device-timeout=2,x-systemd.requires=cloud-init.service", "0", "0"]
EOF

#Configure cloud-init telemetry to assist with troubleshooting for provisioning issues:
sudo tee >> /etc/cloud/cloud.cfg.d/10-azure-kvp.cfg << EOF
Reporting:
  logging:
    type: log
  telemetry:
    type: hyperv
EOF

# Adding configuration that resolves the issue when the VM boots and prevents root login using SSH, which was needed for the scenario this was created for
# Again, do your own due diligence to determine if you actually need this.
#  1: Enable password-based authentication for SSH
#  2: Allow root login via SSH (even if a password is required)
#  3: Ensure root login is explicitly allowed
#  4: Disable public key authentication (forces password login instead)
#  5: Restart SSH service to apply changes
sudo sed -i 's/^#\?PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PubkeyAuthentication yes/PubkeyAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd

#set yet again root not to be disabled, this file may not exist so making sure we create it.

if [ ! -f /etc/cloud/cloud.cfg.d/99-custom.cfg ]; then
    sudo touch /etc/cloud/cloud.cfg.d/99-custom.cfg
fi
    sudo sed -i 's/^disable_root:.*/disable_root: False/' /etc/cloud/cloud.cfg.d/99-custom.cfg || echo "disable_root: False" | sudo tee -a /etc/cloud/cloud.cfg.d/99-custom.cfg > /dev/null
    sudo sed -i 's/^ssh_pwauth:.*/ssh_pwauth: True/' /etc/cloud/cloud.cfg.d/99-custom.cfg || echo "ssh_pwauth: True" | sudo tee -a /etc/cloud/cloud.cfg.d/99-custom.cfg > /dev/null

# Force the kernel work nicely with Azure Serial Console, this resolves the garbage output previously seen on the serial port
sudo grubby --update-kernel=ALL --args="console=ttyS0,115200n8 earlyprintk=ttyS0,115200"

#Unregister VM from Red Hat Subscription Manager#
echo "y" | sudo subscription-manager unregister

#Clean shell history and shut down the VM
export HISTSIZE=0

#reset cloud-init preparing VM for first-boot initialization in Azure, note if you are using SSH at this point the connection will drop as it releases and renews it's IP address
sudo cloud-init clean
sudo systemctl restart cloud-init

#At tis point you would normally clean up the existing provisioning details, however, for this scenario we were creating a specialised image so we won't do this
#sudo waagent -force -deprovision

#Turn off the VM ready for vhdx converstion to vhd using Hyper-V Manager & Edit disk
poweroff

# Now convert to a fixed VHD format, if using Hyper-V, use edit disk to achieve this, if redhat use quemu-img
# Once converted, upload to an Azure Storage Account
# Next create a managed disk using the VHD located in the storage account, ensuring to select the right generation of VM
# based on your configuration here in this file (BIOS/Gen1 OR UEFI/Gen2)
# Next create a VM using the managed disk, ensure you select the right generation of VM based
# Finally before you power on, ensure there is a NSG that's protecting your VM SSH port from the internet!


