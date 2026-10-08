import uuid
from fastapi import APIRouter, UploadFile, File, HTTPException, Form, Depends
from supabase import create_client, Client
from app.core.config import settings
from app.api import deps
from app.models.user import User, UserRole

router = APIRouter()

# เชื่อมต่อ Supabase
try:
    supabase: Client = create_client(settings.SUPABASE_URL, settings.SUPABASE_KEY)
except Exception as e:
    print(f"⚠️ Supabase Connection Error: {e}")

# 🟢 Config ของแต่ละ Bucket (เพิ่มถัง theme สำหรับรูปร้านค้า)
BUCKET_CONFIG = {
    "lotto": {
        "name": "images_show",
        "allowed": {"jpg", "jpeg", "png", "gif", "webp"},
        "max_size": 2 * 1024 * 1024  # 2MB
    },
    "slip": {
        "name": "slips",
        "allowed": {"jpg", "jpeg", "png"},
        "max_size": 5 * 1024 * 1024  # 5MB
    },
    "theme": {
        "name": "shop_assets",
        "allowed": {"jpg", "jpeg", "png", "webp"},
        "max_size": 5 * 1024 * 1024  # 5MB (รองรับภาพพื้นหลัง HD)
    }
}

# --- 1. API อัปโหลดรูปภาพ (POST) ---
@router.post("/", response_model=dict)
async def upload_image(
    file: UploadFile = File(...),
    folder: str = Form("lotto") # รับค่า folder ว่าจะลงถังไหน (default = lotto)
):
    try:
        # 1. ตรวจสอบว่า folder ที่ส่งมาถูกต้องไหม
        if folder not in BUCKET_CONFIG:
            raise HTTPException(status_code=400, detail="หมวดหมู่โฟลเดอร์ไม่ถูกต้อง")
            
        config = BUCKET_CONFIG[folder]
        bucket_name = config["name"]

        # 2. ตรวจสอบว่ามีไฟล์จริงไหม
        if not file.filename:
            raise HTTPException(status_code=400, detail="ไม่พบไฟล์ที่อัปโหลด")

        # 3. ตรวจสอบประเภทและนามสกุลไฟล์
        if not file.content_type.startswith("image/"):
             raise HTTPException(status_code=400, detail="อนุญาตเฉพาะไฟล์รูปภาพเท่านั้น")

        filename = file.filename.lower()
        if "." not in filename:
             raise HTTPException(status_code=400, detail="ชื่อไฟล์ไม่ถูกต้อง")
        
        file_ext = filename.rsplit(".", 1)[-1]
        if file_ext not in config["allowed"]:
            raise HTTPException(
                status_code=400, 
                detail=f"ไม่อนุญาตไฟล์นามสกุล .{file_ext} สำหรับหมวดหมู่นี้"
            )

        # 4. อ่านและตรวจสอบขนาดไฟล์
        file_content = await file.read()
        if len(file_content) > config["max_size"]:
            raise HTTPException(status_code=400, detail=f"ขนาดไฟล์ใหญ่เกินไป (Max {config['max_size']/1024/1024}MB)")
        
        # 5. เปลี่ยนชื่อไฟล์เป็น UUID เพื่อป้องกันชื่อซ้ำ
        new_filename = f"{uuid.uuid4()}.{file_ext}"

        # 6. อัปโหลดขึ้น Supabase
        res = supabase.storage.from_(bucket_name).upload(
            path=new_filename,
            file=file_content,
            file_options={"content-type": file.content_type}
        )

        # 7. สร้าง Public URL เพื่อส่งกลับไปให้ Frontend แสดงผล
        public_url = f"{settings.SUPABASE_URL}/storage/v1/object/public/{bucket_name}/{new_filename}"

        return {
            "message": "อัปโหลดสำเร็จ", 
            "url": public_url,
            "filename": new_filename
        }
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"Upload Error: {e}")
        raise HTTPException(status_code=500, detail=f"เกิดข้อผิดพลาดในการอัปโหลด: {str(e)}")


# --- 2. API ลบรูปภาพ (DELETE) [เพิ่มใหม่] ---
@router.delete("/", response_model=dict)
async def delete_image(
    file_url: str,           # รับเป็น URL เต็มของรูปภาพที่หน้าบ้านมีอยู่แล้ว
    folder: str = "theme",   # ระบุว่ามาจากโฟลเดอร์/ถังไหน
    current_user: User = Depends(deps.get_current_active_user)
):
    """
    API สำหรับลบไฟล์ภาพออกจากระบบ (จำกัดสิทธิ์เฉพาะแอดมิน)
    """
    # 1. ตรวจสอบสิทธิ์ (เพื่อความปลอดภัย ไม่ให้ใครก็ไม่รู้มาสั่งลบรูป)
    if current_user.role not in [UserRole.admin, UserRole.superadmin]:
        raise HTTPException(status_code=403, detail="ไม่มีสิทธิ์ลบรูปภาพ")

    # 2. ตรวจสอบ Folder Configuration
    if folder not in BUCKET_CONFIG:
        raise HTTPException(status_code=400, detail="หมวดหมู่โฟลเดอร์ไม่ถูกต้อง")
        
    bucket_name = BUCKET_CONFIG[folder]["name"]

    # 3. สกัดชื่อไฟล์ออกจาก URL (เช่น https://.../shop_assets/1234-abcd.jpg -> 1234-abcd.jpg)
    try:
        # ตัดเอาส่วนสุดท้ายของ URL มาเป็นชื่อไฟล์ และตัดพวก Query string (ถ้ามี) ออก
        filename = file_url.split("/")[-1].split("?")[0]
        
        if not filename or filename == "":
            raise ValueError("Extract filename failed")
    except Exception:
        raise HTTPException(status_code=400, detail="URL รูปภาพไม่ถูกต้อง")

    # 4. สั่งลบไฟล์จาก Supabase
    try:
        # supabase .remove() ต้องการรับ parameter เป็น list ของ path
        res = supabase.storage.from_(bucket_name).remove([filename])
        
        return {
            "message": "ลบรูปภาพเก่าสำเร็จ", 
            "deleted_file": filename
        }
    except Exception as e:
        print(f"Delete Image Error: {e}")
        raise HTTPException(status_code=500, detail=f"เกิดข้อผิดพลาดในการลบรูปภาพจากระบบ: {str(e)}")