from subprocess import check_output

ip = check_output('ifconfig').decode().split('     ')[:-1][13:14][0].split()[1].splitlines()[0]

print(ip)
