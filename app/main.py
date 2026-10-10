from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.core.config import settings
from app.api.v1.router import api_router

from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from app.core.limiter import limiter

app = FastAPI(
    title="shop Multi-Tenant API",
    description="ระบบจัดการร้านค้าออนไลน์ระดับ Production",
    version="1.0.0"
)
app.state.limiter = limiter
# 🌟 3. บอกแอพว่า ถ้าใครยิงเกินโควตา ให้ตอบกลับด้วย Error ของ slowapi
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

origins = [
    "https://service-zeta-nine.vercel.app",
    "http://localhost:5173",
    "http://127.0.0.1:5173",
    "http://localhost:3000",
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    # รองรับทั้ง preview branches ของ vercel และ localhost พอร์ตอื่นๆ ทั้งหมด
    allow_origin_regex=r"^https?:\/\/(localhost(:\d+)?|127\.0\.0\.1(:\d+)?|([a-zA-Z0-9-]+\.)*vercel\.app)$",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)

app.include_router(api_router, prefix="/api/v1")


# 3. Health Check สำหรับ Cloud Run
@app.get("/")
def root():
    return {
        "status": "online",
        "message": "Welcome to shop API System",
        "version": "1.0.1"
    }

# หมายเหตุ: ไม่ต้องใส่ uvicorn.run ตรงนี้ 
# เพราะ Dockerfile ของเราใช้ Gunicorn รันจากภายนอกอยู่แล้ว
