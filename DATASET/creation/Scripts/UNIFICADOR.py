import os
import subprocess

carpetas_a_convertir = ["AudioSet/audios_extraidos_eval", "AudioSet/audios_extraidos_balanced_train",
                        "COUGHVID/audios_extraidos",
                        "ESC-50/audios_extraidos",
                        "FSD50K/audios_extraidos_dev", "FSD50K/audios_extraidos_eval"]
carpeta_unificada = "dataset_final_16khz"
os.makedirs(carpeta_unificada, exist_ok = True)

archivos_existentes = set(os.listdir(carpeta_unificada))
archivos_convertidos = 0
for carpeta in carpetas_a_convertir:
    print(f"Convirtiendo carpeta {carpeta}")
    if os.path.exists(carpeta):
        for archivo in os.listdir(carpeta):
            if archivo.endswith(".wav"):
                ruta_origen = os.path.join(carpeta, archivo)
                ruta_destino = os.path.join(carpeta_unificada, archivo)

                if archivo not in archivos_existentes: # Filtro archivos existentes
                    # Convierte a 16kHz (-ar 16000) y Mono (-ac 1)
                    cmd = ['ffmpeg', '-y', '-i', ruta_origen, '-ar', '16000', '-ac', '1', ruta_destino]

                    try:
                        subprocess.run(cmd, check = True, stdout = subprocess.DEVNULL, stderr = subprocess.DEVNULL)
                        archivos_convertidos += 1
                    except subprocess.CalledProcessError:
                        print(f"- Error convirtiendo: {archivo}")
    print(f"- {archivos_convertidos} audios convertidos hasta ahora")

print(f"{archivos_convertidos} nuevos audios han sido estandarizados y movidos a 'dataset_final_16khz'.")
