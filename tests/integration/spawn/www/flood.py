import sys
sys.stdout.write("Content-Type: text/plain\r\n\r\n")
chunk = "A" * 65536
while True: sys.stdout.write(chunk)
