import time
import psutil
import os
import binascii
from Crypto.Cipher import AES
from Crypto.Random import get_random_bytes

CPU_TDP_WATTS = 15
NUM_ITERATIONS = 1000


# -------------------------------------------------------
# CRC32 Function
# -------------------------------------------------------
def compute_crc32(data: bytes):
    return binascii.crc32(data) & 0xFFFFFFFF


# -------------------------------------------------------
# PKCS7 Padding
# -------------------------------------------------------
def pad(data: bytes) -> bytes:
    pad_len = 16 - (len(data) % 16)
    return data + bytes([pad_len]) * pad_len

def unpad(data: bytes) -> bytes:
    pad_len = data[-1]
    return data[:-pad_len]


# -------------------------------------------------------
# AES-128 Encrypt / Decrypt
# -------------------------------------------------------
def aes_encrypt(plaintext: bytes, key: bytes):
    cipher = AES.new(key, AES.MODE_ECB)
    return cipher.encrypt(pad(plaintext))

def aes_decrypt(ciphertext: bytes, key: bytes):
    cipher = AES.new(key, AES.MODE_ECB)
    return unpad(cipher.decrypt(ciphertext))


# -------------------------------------------------------
# POWER MEASUREMENT LOOP
# -------------------------------------------------------
def measure_power_loop(func, data, key):
    process = psutil.Process(os.getpid())

    cpu_before = sum(process.cpu_times()[:2])
    t_before = time.time()

    for _ in range(NUM_ITERATIONS):
        output = func(data, key)

    t_after = time.time()
    cpu_after = sum(process.cpu_times()[:2])

    wall = t_after - t_before
    cpu_used = cpu_after - cpu_before

    cpu_percent = (cpu_used / wall) * 100

    avg_time = wall / NUM_ITERATIONS
    avg_power = (cpu_percent / 100) * CPU_TDP_WATTS
    avg_energy = avg_power * avg_time

    return output, cpu_percent, avg_time, avg_power, avg_energy


# -------------------------------------------------------
# MAIN PROGRAM
# -------------------------------------------------------
if _name_ == "_main_":
    print("\n🟦 SECUSILICON AES SOFTWARE POWER DEMO\n")

    # -------- USER INPUT --------
    user_text = input("Enter plaintext to encrypt: ").encode()

    # Generate random AES-128 key
    key = get_random_bytes(16)

    # Add CRC
    crc_val = compute_crc32(user_text)
    data_block = user_text + crc_val.to_bytes(4, "big")

    # ---------------------- ENCRYPTION ----------------------
    ciphertext, cpu_enc, t_enc, p_enc, e_enc = measure_power_loop(
        aes_encrypt, data_block, key
    )

    print("\n🔐 ENCRYPTION RESULT")
    print("Ciphertext (hex):", ciphertext.hex())
    print(f"Avg Time: {t_enc*1000:.4f} ms")
    print(f"CPU Load: {cpu_enc:.2f}%")
    print(f"Power: {p_enc:.6f} W")
    print(f"Energy per encryption: {e_enc:.10f} J")


    # ---------------------- DECRYPTION ----------------------
    decrypted, cpu_dec, t_dec, p_dec, e_dec = measure_power_loop(
        aes_decrypt, ciphertext, key
    )

    # Remove CRC before showing text
    decrypted_text = decrypted[:-4]

    print("\n🔓 DECRYPTION RESULT")
    print("Decrypted Text:", decrypted_text.decode())
    print(f"Avg Time: {t_dec*1000:.4f} ms")
    print(f"CPU Load: {cpu_dec:.2f}%")
    print(f"Power: {p_dec:.6f} W")
    print(f"Energy per decryption: {e_dec:.10f} J")


    # ------------ SUMMARY ------------
    print("\n🟪 SOFTWARE POWER SUMMARY")
    print(f"Encryption Energy: {e_enc:.10f} J")
    print(f"Decryption Energy: {e_dec:.10f} J")

    print("\n🎉 Measurement Complete.\n")