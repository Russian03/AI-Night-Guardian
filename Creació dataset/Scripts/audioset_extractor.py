import pandas as pd
import subprocess
import os

# type = "balanced_train"
type = "eval"

# CSV metadatos; AudioSet incluye 3 líneas iniciales de comentarios
df = pd.read_csv(f'{type}_segments.csv', skiprows = 3, quotechar = '"', skipinitialspace = True)
df.columns = ['YTID', 'start_seconds', 'end_seconds', 'positive_labels']

# Clases objetivo
categorias = {
    '/m/07p6fty': 'shout',
    '/m/07sr1lc': 'yell',
    '/m/03qc9zr': 'screaming',
    '/m/0463cq4': 'cryingsobbing',
    '/t/dd00002': 'babyinfantcry',
    '/m/07mzm6': 'wheeze',
    '/m/01d3sd': 'snoring',
    '/m/01b_21': 'cough',
    '/m/01hsr_': 'sneeze',
    '/m/07qnq_y': 'thumpthud',
    '/m/07pws3f': 'bang',
    '/m/028v0c': 'silence',
    '/m/09x0r': 'speech',
    '/m/02rtxlg': 'whispering',
    '/m/01j3sz': 'laughter',
    '/m/0lyf6': 'breathing',
    '/m/07pbtc8': 'walkfootsteps',
    '/m/03q5_w': 'burpingeructation',
    '/m/07rkbfh': 'chatter',
    '/m/0jb2l': 'thunderstorm',
    '/m/0838f': 'water',
    '/m/0912c9': 'vehiclehorncarhornhonking',
    '/t/dd00134': 'carpassingby',
    '/m/03j1ly': 'emergencyvehicle',
    '/m/0btp2': 'trafficnoiseroadwaynoise',
    '/m/02dgv': 'door',
    '/m/046dlr': 'alarmclock',
    '/t/dd00125': 'insidesmallroom'
}
target_ids = list(categorias.keys())

# Filtro dataframe
pattern = '|'.join(target_ids)
filtered_df = df[df['positive_labels'].str.contains(pattern, na = False)]

# Filtro archivos existentes
dir = f"audios_extraidos_{type}"
os.makedirs(dir, exist_ok = True)
archivos_existentes = set(os.listdir(dir))
# Función filtro
def necesita_descarga(row):
    etiquetas = row['positive_labels']
    categoria = ""
    for cod_id, nombre_cat in categorias.items():
        if cod_id in etiquetas:
            categoria = categoria + nombre_cat
            break
    nombre_archivo = f"{categoria}_{row['YTID']}_{row['start_seconds']}_{row['end_seconds']}.wav"
    return nombre_archivo not in archivos_existentes
filtered_df = filtered_df[filtered_df.apply(necesita_descarga, axis = 1)]

# Filtro videos no disponibles en youtube
df_unavailable = pd.read_csv("unavailables_yt.csv", header = None, names = ['YTID'])
ids_ignorados = set(df_unavailable['YTID'].astype(str))
filtered_df = filtered_df[~filtered_df['YTID'].isin(ids_ignorados)]

print(f"Encontradas {len(filtered_df)} nuevas muestras útiles.")

# Descargar y recortar
for idx, (index, row) in enumerate(filtered_df.iterrows(), start = 1):
    yt_id = row['YTID']
    start = row['start_seconds']
    end = row['end_seconds']
    etiquetas = row['positive_labels']
    url = f"https://www.youtube.com/watch?v={yt_id}"

    categoria = ""
    for cod_id, nombre_cat in categorias.items():
        if cod_id in etiquetas:
            categoria = categoria + nombre_cat
            break
    out_name = f"{dir}/{categoria}_{yt_id}_{start}_{end}.wav"

    # yt-dlp extrae el wav, recorta el tiempo exacto y fuerza 16kHz mono para TinyML
    cmd = ['yt-dlp', '-x', '--audio-format', 'wav', '--postprocessor-args', f"-ss {start} -to {end} -ar 16000 -ac 1", '-o', out_name, url]
    try:
        subprocess.run(cmd, check = True, stdout = subprocess.DEVNULL, stderr = subprocess.PIPE, text = True)
        print(f"- {idx}. Descargado: {out_name}")
    except subprocess.CalledProcessError as e:
        error_msg = e.stderr.lower() if e.stderr else ""
        if any(keyword in error_msg for keyword in ["video unavailable", "video is unavailable", "video is not available", "private video", "removed", "copyright", "account has been terminated"]):
            print(f"- {idx}. Omitido (No disponible en YT): {url}")
            with open("unavailables_yt.csv", "a") as f_unavailable:
                f_unavailable.write(f"{yt_id}\n")
        else:
            print(f"- {idx}. Error técnico (yt-dlp/FFmpeg) en {url} -> Detalle: {error_msg.strip()}")
    except Exception as e:
        print(f"- {idx}. Fallo inesperado con {url}: {e}")
