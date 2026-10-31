# CooVox ↔ Kamailio SIP Bridge — Stable v1.0.0

**عربي | [English technical reference](docs/TECHNICAL_REFERENCE.md)**

> إصدار توثيقي قابل لإعادة الإنتاج لربط بدالة ZYCOO CooVox عبر OpenVPN بسيرفر Ubuntu يعمل عليه Kamailio وRTPengine. يتضمن إصلاح تسجيل الرقم الواحد على أجهزة متعددة، ورنينها بالتوازي، واختيار الواجهة الصحيحة لإرسال SIP. **هذا المستودع عام لكن لا يحتوي بيانات تشغيل فعلية أو أسرار.**

## الحالة المعتمدة

- **الإصدار:** `v1.0.0` (30 أكتوبر 2026).
- **بيئة الاختبار:** Ubuntu 24.04 LTS، Kamailio 5.7.4، RTPengine 11.5.1، OpenVPN 2.6.
- **الاختبار الفعلي:** تأكد تسجيل أكثر من جهاز على رقم واحد؛ اتصال الرقم 100 إلى 112؛ والرنين الوارد من 112 إلى 100 على MicroSIP وCooCall وFanvil.
- **نقطة رجوع الإنتاج:** محفوظة بشكل خاص على السيرفر، وليست على GitHub.
- **مهم:** نجاح اختبار الرنين لا يثبت تلقائياً جودة الصوت أو حفظ التسجيلات الصوتية في جميع السيناريوهات.

## المخطط العام

```text
Fanvil / MicroSIP / CooCall (Internet)
          │ SIP UDP :15060
          ▼
VPS public interface → NAT REDIRECT :17060
          │
          ▼
    Kamailio SIP Edge   ─── RTPengine (public ↔ VPN media)
          │  UDP 17060/17061/17062
          ▼
    OpenVPN tunnel
          │
          ▼
    CooVox PBX UDP :5060
          │
          └─ PBX authenticates REGISTER; extension limit configured there
```

**لماذا نجح الإصلاح؟** قبل v1.0.0 كان Kamailio يحفظ عنواناً واحداً فقط للامتداد العادي، ويستخدم واجهة VPN عنواناً لإرسال بعض فروع `INVITE` عبر الإنترنت. الآن يحتفظ حتى بخمسة منافذ تسجيل مستقلة للرقم الواحد، ويرسل **جميع فروع الرنين الخارجية من واجهة SIP العامة** باستخدام `branch_route[PUBLIC_FORK]`. يُخزّن `app_100` (CooCall) منفصلاً.

## الوظائف الحالية

1. **التحقق من الحساب:** يتم بواسطة CooVox وحدها؛ Kamailio لا يعرف كلمة المرور ولا يقرر صحتها.
2. **تعدد الأجهزة:** يحتفظ Kamailio بمنافذ وأزمنة التسجيلات المقبولة، ويدعم حتى 5 جهات اتصال عادية لكل رقم في الخطة `100–199`.
3. **الرنين المتوازي:** يرسل الفرع الوارد من البدالة إلى الأجهزة المسجلة، بالإضافة إلى فرع CooCall `app_` إن وجد.
4. **الاستمرار أثناء المكالمة:** يربط مسار المكالمة بالجهاز المجيب، حتى إذا جدد جهاز آخر تسجيله.
5. **حماية SIP:** يمنع `INVITE` من عنوان/منفذ لم يُقبل تسجيله، ويحدّ طلبات `REGISTER` على نافذة زمنية ثابتة، دون منع شرعي دائم بسبب عداد لا يُصفّر.
6. **وسائط الصوت:** يديرها RTPengine بمجال منافذ مستقل، وتبقى قواعد NAT القديمة للرجوع منظّمة بحيث تتقدم قاعدة توجيه Kamailio عليها.

## محتويات المستودع

| الملف / المجلد | الوظيفة |
|---|---|
| `templates/kamailio/coovox.cfg.tpl` | قالب **الإعداد الذي اختُبر فعلياً** مع استبدال عناوين الخادم والبدالة بقيم متغيرة |
| `templates/rtpengine/coovox.conf.tpl` | قالب وسيط RTP |
| `templates/network/` | قاعدة توجيه SIP العام والقواعد القديمة للتوافق/الرجوع (ليست أوامر نشر تلقائي) |
| `templates/systemd/` | وحدات النظام وقالب ضبط MTU |
| `scripts/render_config.py` | توليد ملفات إعداد فعلية من `.env` المحلي |
| `scripts/check-health.sh` | فحوص آمنة للقراءة فقط |
| `scripts/backup.sh` و `scripts/rollback.sh` | نسخة احتياطية محلية واسترجاع منظّم |
| `docs/OPERATIONS_AR.md` | دليل إدارة واستكشاف الأعطال باللغة العربية |
| `docs/TECHNICAL_REFERENCE.md` | وصف هندسي وتقني كامل باللغة الإنجليزية |
| `docs/DEPLOYMENT.md` | المتطلبات وإجراءات النشر الآمن |
| `docs/RESTORE.md` | استراتيجية الاستعادة ومخاطر الرجوع |
| `docs/SECURITY.md` | عزل أسرار التشغيل وتقليل التعرض الأمني |
| `docs/TESTING.md` | سيناريوهات الاختبار والنتائج والقيود |
| `docs/KNOWN_ISSUES.md` | مشاكل معروفة لم نعلن حلّها |
| `VERSION.json` و `CHANGELOG.md` | رقم الإصدار وتاريخ الإصلاحات |

## البدء السريع — بيئة منفصلة فقط

```bash
git clone https://github.com/ali-alshalah/coovox-kamailio-multidevice-bridge.git
cd coovox-kamailio-multidevice-bridge
cp .env.example .env
# عدّل .env وأدخل عناوين بيئتك، وليس أسرار المصادقة
python3 scripts/render_config.py --env .env --output build
kamailio -c -f build/coovox.cfg
python3 -m unittest discover -s tests -v
```

**لا تنسخ `build/` إلى الإنتاج مباشرة.** اقرأ أولاً [DEPLOYMENT.md](docs/DEPLOYMENT.md) وأنشئ نقطة رجوع. يجب أن يتطابق نطاق منافذ RTP وNAT وأسماء واجهات VPN وخطة الأرقام مع بيئتك. القواعد القديمة في `templates/network/*LEGACY.tpl` ليست المسار النشط الموصى به.

## استكشاف العطل بسرعة

| العَرَض | الفحص الأول | المرجع |
|---|---|---|
| `Timeout / Service Unavailable` عند التسجيل | الوصول إلى UDP 15060، تحويل NAT، رد Kamailio، اتصال VPN | [OPERATIONS_AR.md](docs/OPERATIONS_AR.md) |
| `503 REGISTER Rate Limited` | عداد الحد لكل IP والنافذة الزمنية | [OPERATIONS_AR.md](docs/OPERATIONS_AR.md) |
| `401` متكرر بعد إرسال بيانات Digest | كلمة مرور SIP / الحساب داخل البدالة، لا تُفترض مشكلة شبكة | [KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) |
| جهاز مسجّل يتصل للخارج ولا يرن عند الوارد | فروع `INVITE` واختيار **public send socket** لكل فرع | [TECHNICAL_REFERENCE.md](docs/TECHNICAL_REFERENCE.md) |
| يرن جهاز واحد فقط من الرقم ذاته | جدول `regmulti`، حد CooVox، فترة صلاحية جهة الاتصال | [OPERATIONS_AR.md](docs/OPERATIONS_AR.md) |
| فشل الصوت / `Ran out of ports` | تدفق INVITE غير مسجل، RTPengine، منافذ UDP المتاحة | [SECURITY.md](docs/SECURITY.md) |

## أين أجد النسخة المستقرة الحقيقية؟

GitHub يحفظ **قوالب قابلة للنشر وتعليمات**، وليس البيانات الخاصة بالسيرفر. يجب تخزين لقطة الإنتاج **خارج المستودع العام** (Kamailio config + SQLite + systemd + ضبط RTP + أسرار VPN في مخزن سري منفصل). رقم Git Tag `v1.0.0` هو المرجع المعتمد لهذه القوالب. ملفات `*.sqlite` و`*.pcap` و`.env` والكلمات السرية مستبعدة من Git.

## حدود النطاق

المشروع يغطي جسر CooVox ↔ Kamailio وRTPengine/OpenVPN، ولا يدّعي أنه يحتوي كامل نظام البدالة أو جميع حاويات/تطبيقات VPS. تسجيل الصوت الفعلي داخل البدالة، والامتداد 151 الذي كان يعيد `401`، مشكلتان مستقلتان لا يوثّق هذا الإصدار حلّهما.

**للمساهمات:** أرسل طلب دمج موثقاً بالاختبارات. لا ترفع سجلات SIP الخام أو قواعد بيانات التسجيل أو أسرار الإنتاج. راجع [SECURITY.md](docs/SECURITY.md).

## إضافة اختيارية: المحافظة على مسار UDP للرقم 100

راجع [دليل إضافة OPTIONS Keepalive](docs/FANVIL_UDP_KEEPALIVE_AR.md). تضيف فحصاً دورياً للجهات المصادَق عليها دون تعديل ملف Kamailio الأساسي أو علامة `v1.0.0`. تم التحقق من ردود Fanvil وMicroSIP أثناء اختبار قصير؛ تقييم الاستقرار الطويل ما زال مطلوباً.
