# إضافة المحافظة على تسجيل Fanvil / الرقم 100 — 2026-10-31

## الحالة والنطاق

هذه إضافة مستقلة إلى الإصدار المرجعي `v1.0.0`، وليست استبدالاً لإعداد Kamailio المستقر. تعمل بواسطة systemd Timer كل 15 ثانية تقريباً، وتطلب من Kamailio إرسال **SIP OPTIONS فقط** إلى جهات الاتصال الحديثة المسموح بها للرقم `100`. تتكيف مع تغير منفذ الجهاز بعد نجاح تسجيل جديد في البدالة. لم تُغيَّر مسارات SIP، أو حماية التسجيل، أو RTPengine، أو الجدار الناري، أو خط الهاتف الثالث `SIP3`.

نجح اختبار حي من 3 دورات: 6 رسائل OPTIONS إلى Fanvil وMicroSIP، و6 ردود `200 OK`. خرجت الطلبات من عنوان السيرفر العام والمنفذ المتوقع. هذه نتيجة اختبار قصير، **وليست ضماناً لعدم حدوث انقطاع طويل الأمد**.

## الأدلة وحدود الاستنتاج

الالتقاط الذي أُخذ من الهاتف وقت العطل تضمن 13 محاولة REGISTER عبر UDP خلال نحو دقيقة دون رد SIP مقابل، بينما ظل حساب آخر عبر TCP يستجيب. عاد هاتف Fanvil لاحقاً بتسجيل جديد ومنفذ NAT مختلف، من دون تغيير ملف Kamailio.

هذا يتوافق مع مشكلة مؤقتة في مسار UDP، لكنه **لا يثبت وحده** أن الراوتر أو SIP ALG هو السبب. تغير منفذ NAT أمر ممكن أيضاً بعد إعادة التشغيل. لا يُقدّم هذا التعديل بوصفه إصلاحاً مؤكداً لكل مكونات المسار التي لم تُفحص.

## لماذا OPTIONS؟

الطلب ينتج حركة ذهاب وإياب: الخادم يرسل OPTIONS والجهاز يرد عليها. يساعد ذلك على إبقاء مسار NAT نشطاً بدلاً من الاعتماد فقط على حزم UDP صغيرة باتجاه واحد أو فحوص PBX التي قد تستهدف آخر جهاز سجل حساباً مشتركاً. لا يتسبب OPTIONS في رنين الهاتف ولا ينشئ مكالمة أو جلسة صوت.

المرجع الرسمي: https://www.kamailio.org/docs/modules/5.7.x/modules/tm.html#tm.rpc.t_uac_start
ومبدأ الفحص ثنائي الاتجاه: https://www.kamailio.org/docs/modules/5.7.x/modules/nathelper.html

## ملفات الإضافة

- `/usr/local/lib/coovox/registration_keepalive.py`
- `/etc/kamailio/registration-keepalive.json` — إعداد محلي خاص، لا يُرفع إلى المستودع.
- `coovox-registration-keepalive.service` — عملية قصيرة تعمل بحساب `kamailio` وليست root.
- `coovox-registration-keepalive.timer` — تبدأ تلقائياً بعد إقلاع السيرفر، وتتكرر كل 15 ثانية تقريباً.
- `/var/lib/coovox-nat-keepalive/status.json` — حالة إرسال محلية؛ لا تحتوي كلمة مرور أو محتوى صوتياً.

القائمة المسموح بها في الإنتاج هي `['100']` فقط. لا تشمل `cw1` أو `app_100` أو أي حساب آخر. تحتوي خيارات `regmulti` على الجهازين العاديين (Fanvil وMicroSIP)؛ يستهدف كل منهما على حدة، ولا يلمس SIP3.

## ضوابط الأمان

1. الوجهات مأخوذة حصراً من `regmulti` المقبول سابقاً بواسطة البدالة، وليست من طلب REGISTER غير مصادق.
2. يشترط وجود `#ts` حديث ضمن 3600 ثانية، بما يطابق حد صلاحية المسار في الإصدار المرجعي. هذه ليست إعادة تنفيذ لجميع قواعد مدة التسجيل الفعلية في PBX.
3. تُرفض الوجهات المحلية والخاصة وlink-local وmulticast، والمنافذ خارج 1024–65535.
4. حد أقصى خمسة عناوين في كل دورة، مع حذف التكرار.
5. لا تعدّل الإضافة جدول التسجيل، ولا تجدد مدة المصادقة بناءً على OPTIONS، ولا تنشئ تسجيلاً وهمياً، ولا تحذف جهازاً عند غياب الرد.
6. تستخدم RPC عبر Unix المحلي؛ لا تفتح منفذاً عاماً أو خدمة تحكم على الإنترنت.
7. لا تستخدم `tm.t_uac_wait_block`، كي لا تحتجز عملية RPC أثناء انتظار هاتف غير متصل.
8. لا تعيد تشغيل أي هاتف أو خدمة عند فشل فحص.
9. `options_queued` في ملف الحالة يعني قبول طلب الإرسال محلياً، **ولا يعني أن الجهاز رد**. إثبات الرد يكون بتتبع SIP متطابق الـCall-ID أثناء الاختبار.

### ملاحظة تنفيذ مهمة

يجب تمرير معاملات `kamcmd` النصية بالبادئة `s:`، وخاصة الجسم الفارغ `s:`. قد يُعامل النص الفارغ غير المسبوق بالبادئة كعدد صفر ويولد `Content-Type missing`. الاختبارات تشمل هذه الحالة وتفحص خطأ RPC حتى لو أعاد البرنامج exit code 0.

## النشر في بيئة أخرى

ولّد القالب باستخدام بيانات بيئتك المحلية ثم راجع القائمة المسموح بها:

```bash
python3 scripts/render_config.py --env .env --output build
sudo install -d -m 755 /usr/local/lib/coovox
sudo install -o root -g root -m 755 scripts/registration_keepalive.py /usr/local/lib/coovox/
sudo install -o root -g kamailio -m 640 build/registration-keepalive.json /etc/kamailio/
sudo install -m 644 templates/systemd/coovox-registration-keepalive.service /etc/systemd/system/
sudo install -m 644 templates/systemd/coovox-registration-keepalive.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo python3 /usr/local/lib/coovox/registration_keepalive.py --dry-run
sudo systemctl start coovox-registration-keepalive.service
# افحص نجاح الاختبار، ثم فعّل التكرار:
sudo systemctl enable --now coovox-registration-keepalive.timer
```

عنوان السيرفر في المثال يجب استبداله بعنوان IPv4 عام حقيقي تابع لك. قد ترفض الإضافة عناوين التوثيق أو الشبكة المحلية عمداً. عند عدم توافق المصدر مع خطط NAT يجب عدم تفعيل المؤقت قبل فحص مصدر OPTIONS ورد الهاتف.

## الفحص

```bash
systemctl is-enabled coovox-registration-keepalive.timer
systemctl status coovox-registration-keepalive.timer --no-pager
systemctl show -p Result -p ExecMainStatus coovox-registration-keepalive.service
journalctl -u coovox-registration-keepalive.service -n 10 --no-pager
sudo cat /var/lib/coovox-nat-keepalive/status.json
```

تبدأ Call-ID الخاصة بهذه الطلبات بـ`coovoxka-`. لا تُحمّل بيانات PCAP أو IP الإنتاج أو حالة الأجهزة إلى مستودع عام. للاختبار البرمجي شغّل `python3 -m unittest discover -s tests -v`؛ لا تُرسل اختبارات بيانات وهمية إلى PBX الإنتاج.

## الرجوع دون قطع المكالمات

```bash
sudo systemctl disable --now coovox-registration-keepalive.timer
sudo systemctl stop coovox-registration-keepalive.service
```

يوقف هذا الإضافة وحدها؛ لا يحتاج إلى استرجاع `coovox.cfg` ولا إعادة تشغيل Kamailio أو RTPengine. يحتفظ الإنتاج بنقطة رجوع خاصة قبل التفعيل. علامة `v1.0.0` لا تُنقل ولا يُكتب فوقها.

## ما الذي لا تصلحه الإضافة؟

لا تستطيع رسائل OPTIONS إصلاح Wi-Fi متوقف، أو منع دائم لحزم UDP قبل وصولها، أو خطأ إعداد DNS، أو تغيير كلمة مرور، أو كسر NAT/ALG في الراوتر. إذا عاد العطل رغم وجود OPTIONS وردودها، اجمع التقاطاً متزامناً من الهاتف ومن السيرفر، وافحص بوابة الشبكة. لا تَعُد إلى إعادة تشغيل الخدمات أو تعطيل الحماية عشوائياً.

مشكلة اختفاء صوت الزبون بعد بدء المكالمة مسألة RTP مستقلة، ولا نعلن أن هذه الإضافة تعالجها.
