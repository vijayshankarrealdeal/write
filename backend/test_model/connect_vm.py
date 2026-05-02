
import paramiko

# VM Connection Details
vm_ip = "20.219.16.30"  # Replace with your VM's IP
username = "azureuser"
password = "Google@990cc"

try:
    # 1. Initialize the SSH Client
    ssh = paramiko.SSHClient()

    # 2. Automatically add the VM to known_hosts (for first-time connection)
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    # 3. Establish the connection
    ssh.connect(hostname=vm_ip, username=username, password=password)

    # 4. Execute a command (e.g., 'ls -l')
    stdin, stdout, stderr = ssh.exec_command('ls -l')

    # 5. Read and print the output
    print(stdout.read().decode())

finally:
    # 6. Always close the connection
    ssh.close()
