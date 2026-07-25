import utils.session
import base64
import json
import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
import io
from scipy.io import wavfile
from pydantic import BaseModel

try:
    import librosa
except ImportError:
    librosa = None

app = FastAPI(title="Voice Changer Backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

DEFAULT_SAMPLE_RATE = 44100


def load_audio_bytes(raw_bytes):
    # Check if WAV file (starts with RIFF)
    if len(raw_bytes) >= 4 and raw_bytes[:4] == b'RIFF':
        try:
            sr, audio_data = wavfile.read(io.BytesIO(raw_bytes))
            # Convert to float32 normalized
            if audio_data.dtype == np.int16:
                audio = audio_data.astype(np.float32) / 32768.0
            elif audio_data.dtype == np.float32:
                audio = audio_data
            else:
                audio = audio_data.astype(np.float32) / np.max(np.abs(audio_data))
            return audio, sr
        except Exception as e:
            print("Failed to read as WAV, trying raw PCM:", e)
    
    # Check if data is likely float32 or int16
    if len(raw_bytes) % 4 == 0:
        try:
            audio_f32 = np.frombuffer(raw_bytes, dtype=np.float32)
            if len(audio_f32) > 0 and np.max(np.abs(audio_f32)) <= 1.5:
                return audio_f32, DEFAULT_SAMPLE_RATE
        except Exception:
            pass

    # Fallback to raw PCM 16-bit
    audio = np.frombuffer(raw_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    return audio, DEFAULT_SAMPLE_RATE


def normalize(audio):
    peak = np.max(np.abs(audio))
    if peak > 0:
        audio = audio / peak
    return audio.astype(np.float32)


def pitch_shift(audio, sample_rate, steps):
    if librosa is None:
        return audio

    try:
        shifted = librosa.effects.pitch_shift(
            y=audio,
            sr=sample_rate,
            n_steps=steps
        )
        return shifted.astype(np.float32)
    except Exception:
        return audio


# -------------------------
# Effects
# -------------------------

def male_voice(audio, sample_rate):
    return pitch_shift(audio, sample_rate, -4)


def female_voice(audio, sample_rate):
    return pitch_shift(audio, sample_rate, 4)


def deep_voice(audio, sample_rate):
    return pitch_shift(audio, sample_rate, -8)


def chipmunk_voice(audio, sample_rate):
    return pitch_shift(audio, sample_rate, 8)


def robot_voice(audio, sample_rate):
    t = np.arange(len(audio)) / sample_rate
    carrier = np.sin(2 * np.pi * 80 * t)
    return audio * carrier


def echo_voice(audio, sample_rate):
    delay_ms = 250
    decay = 0.5

    delay_samples = int(sample_rate * delay_ms / 1000)

    output = np.zeros(len(audio) + delay_samples, dtype=np.float32)

    output[:len(audio)] += audio
    output[delay_samples:] += audio * decay

    return output[:len(audio)]


def distortion_voice(audio):
    gain = 5.0
    return np.tanh(audio * gain)


def radio_voice(audio, sample_rate):
    t = np.arange(len(audio)) / sample_rate
    carrier = np.sin(2 * np.pi * 1000 * t)
    return audio * carrier * 0.8


def alien_voice(audio, sample_rate):
    shifted = pitch_shift(audio, sample_rate, 6)
    return robot_voice(shifted, sample_rate)


# -------------------------
# Effect Dispatcher
# -------------------------

def apply_effect(audio, effect, sample_rate):

    effect = effect.lower()

    if effect == "male":
        return male_voice(audio, sample_rate)

    elif effect == "female":
        return female_voice(audio, sample_rate)

    elif effect == "deep":
        return deep_voice(audio, sample_rate)

    elif effect == "chipmunk":
        return chipmunk_voice(audio, sample_rate)

    elif effect == "robot":
        return robot_voice(audio, sample_rate)

    elif effect == "echo":
        return echo_voice(audio, sample_rate)

    elif effect == "distortion":
        return distortion_voice(audio)

    elif effect == "radio":
        return radio_voice(audio, sample_rate)

    elif effect == "alien":
        return alien_voice(audio, sample_rate)

    return audio


# -------------------------
# API Routes
# -------------------------

@app.get("/")
async def root():
    return {
        "status": "running",
        "service": "Voice Changer Backend"
    }


@app.get("/effects")
async def effects():
    return {
        "effects": [
            "male",
            "female",
            "deep",
            "chipmunk",
            "robot",
            "echo",
            "distortion",
            "radio",
            "alien"
        ]
    }


class ProcessRequest(BaseModel):
    audio: str  # Base64 string of raw PCM 16-bit bytes or WAV bytes
    effect: str
    sample_rate: int = DEFAULT_SAMPLE_RATE


@app.post("/process")
async def process_audio(request: ProcessRequest):
    try:
        raw_audio = base64.b64decode(request.audio)
        audio, sample_rate = load_audio_bytes(raw_audio)
        
        # Override sample rate if request specifies it and it's raw PCM
        if request.sample_rate != DEFAULT_SAMPLE_RATE and raw_audio[:4] != b'RIFF':
            sample_rate = request.sample_rate

        processed = apply_effect(audio, request.effect, sample_rate)
        processed = normalize(processed)
        
        # Write to WAV in memory
        processed_int16 = (processed * 32767.0).astype(np.int16)
        byte_io = io.BytesIO()
        wavfile.write(byte_io, sample_rate, processed_int16)
        
        response_audio = base64.b64encode(byte_io.getvalue()).decode()
        
        return {
            "effect": request.effect,
            "audio": response_audio
        }
    except Exception as e:
        return {"error": str(e)}



# -------------------------
# WebSocket Audio Stream
# -------------------------

@app.websocket("/audio")
async def audio_socket(ws: WebSocket):

    await ws.accept()

    print("Client Connected")

    try:

        while True:

            message = await ws.receive_text()

            packet = json.loads(message)

            effect = packet.get("effect", "none")
            sample_rate = packet.get(
                "sample_rate",
                DEFAULT_SAMPLE_RATE
            )

            encoded_audio = packet["audio"]

            raw_audio = base64.b64decode(
                encoded_audio
            )

            audio, sample_rate_detected = load_audio_bytes(raw_audio)
            if sample_rate == DEFAULT_SAMPLE_RATE or raw_audio[:4] == b'RIFF':
                sample_rate = sample_rate_detected


            processed = apply_effect(
                audio,
                effect,
                sample_rate
            )

            processed = normalize(processed)

            response_audio = base64.b64encode(
                processed.tobytes()
            ).decode()

            await ws.send_text(
                json.dumps({
                    "effect": effect,
                    "audio": response_audio
                })
            )

    except WebSocketDisconnect:
        print("Client Disconnected")

    except Exception as e:
        print("Error:", e)

        try:
            await ws.send_text(
                json.dumps({
                    "error": str(e)
                })
            )
        except Exception:
            pass


# -------------------------
# Run Server
# -------------------------

if __name__ == "__main__":
    uvicorn.run(
        "Main:app",
        host="0.0.0.0",
        port=8000,
        reload=True
    )