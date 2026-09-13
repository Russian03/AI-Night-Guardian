import pandas as pd
import os
import subprocess

carpeta_origen = "public_dataset"
archivo_csv = f'{carpeta_origen}/metadata_compiled.csv'
carpeta_destino = "audios_extraidos"
os.makedirs(carpeta_destino, exist_ok = True)

try:
    df = pd.read_csv(archivo_csv)
except UnicodeDecodeError:
    df = pd.read_csv(archivo_csv, encoding = 'latin1')
df = df.dropna(subset = ['cough_detected'])

# Condición 1: Probabilidad de tos al 95% o superior
mask_cough = df['cough_detected'] >= 0.95
# Condición 2: Calidad 'ok', 'good' o vacía (NaN) en los tres campos
calidades = ['ok', 'good']
mask_q1 = df['quality_1'].isna() | df['quality_1'].isin(calidades)
mask_q2 = df['quality_2'].isna() | df['quality_2'].isin(calidades)
mask_q3 = df['quality_3'].isna() | df['quality_3'].isin(calidades)
mask_calidad = mask_q1 & mask_q2 & mask_q3
# Condición 3: Severidad 'severe' o vacía (NaN) en los tres campos
mask_s1 = df['severity_1'].isna() | (df['severity_1'] == 'severe')
mask_s2 = df['severity_2'].isna() | (df['severity_2'] == 'severe')
mask_s3 = df['severity_3'].isna() | (df['severity_3'] == 'severe')
mask_severidad = mask_s1 & mask_s2 & mask_s3
# Aplicar condiciones
df_final = df[mask_cough & mask_calidad & mask_severidad]

# Filtro archivos existentes
archivos_existentes = set(os.listdir(carpeta_destino))
nombres_virtuales = "tos_coughvid_" + df_final['uuid'].astype(str) + ".wav"
df_final = df_final[~nombres_virtuales.isin(archivos_existentes)]

print(f"Se han encontrado {len(df_final)} nuevas toses de alta confianza.")

# Convertir y copiar
archivos_procesados = 0
for index, row in df_final.iterrows():
    uuid = str(row['uuid'])
    ruta_origen_webm = os.path.join(carpeta_origen, f"{uuid}.webm")
    ruta_origen_ogg = os.path.join(carpeta_origen, f"{uuid}.ogg")
    if os.path.exists(ruta_origen_webm):
        ruta_origen = ruta_origen_webm
    else:
        ruta_origen = ruta_origen_ogg

    if os.path.exists(ruta_origen):
        ruta_destino = os.path.join(carpeta_destino, f"tos_coughvid_{uuid}.wav")

        cmd = ['ffmpeg', '-y', '-i', ruta_origen, '-ar', '16000', '-ac', '1', ruta_destino]
        try:
            subprocess.run(cmd, check = True, stdout = subprocess.DEVNULL, stderr = subprocess.DEVNULL)
            archivos_procesados += 1
            print(f"- Archivo {archivos_procesados} procesado...")
        except subprocess.CalledProcessError:
            print(f"- Error al convertir: {uuid}")

print(f"Completado: {archivos_procesados} muestras añadidas al dataset.")
