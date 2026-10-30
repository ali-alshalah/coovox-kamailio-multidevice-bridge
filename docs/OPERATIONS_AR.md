# دليل التشغيل والصيانة — CooVox ↔ Kamailio v1.0.0

> موجّه لأي مسؤول يتولى المشروع بعدنا. افحص أولاً، ثم أنشئ نسخة احتياطية قبل أي تغيير. **لا ترفع سجلات SIP الخام أو كلمات المرور أو قواعد بيانات الاتصالات إلى GitHub.**

## 1. ما المشروع؟

الهدف ربط هواتف SIP خارج الشبكة (Fanvil وMicroSIP وتطبيق CooCall على iPhone) ببدالة CooVox عبر سيرفر Ubuntu. يتلقى السيرفر SIP، يحميه من الطلبات غير المسجلة، ثم يمرره إلى البدالة عبر OpenVPN. Kamailio يتولى توجيه التسجيلات والمكالمات؛ RTPengine يتولى تحويل وسائط الصوت بين المسارات عند الحاجة؛ البدالة CooVox هي الجهة الوحيدة التي تتحقق من كلمات المرور.

الإصدار المعتمد **v1.0.0 بتاريخ 2026-10-30**. نجاح المكالمات على الرقم 100 من ثلاثة أجهزة أكد عملياً عمل التسجيل المتعدد والرنين المتوازي بعد تصحيح عنوان مصدر فروع SIP.

## 2. مكونات التشغيل

| العنصر | الدور | أين يفحص؟ |
|---|---|---|
| `coovox-kamailio.service` | SIP proxy, RTP engine client, fork rules | `/etc/kamailio/coovox.cfg` |
| `coovox-rtpengine.service` | RTP/SRTP/NAT media relay | `/etc/rtpengine/coovox.conf` |
| `openvpn-server@coovox.service` | ربط VPN إلى البدالة | `/etc/openvpn/server/coovox.conf` (خاص/لا تنشره) |
| `coovox-sip-official-proxy.service` | يجعل UDP 15060 يصل إلى Kamailio على 17060 | `/usr/local/sbin/coovox-sip-official-proxy` |
| `coovox-sip-forward.service` | قاعدة DNAT قديمة مباشرة إلى البدالة (بديل رجوع) | `/usr/local/sbin/coovox-sip-forward` |
| `coovox-rtp-forward.service` | توجيه منافذ PBX الخاصة بـRTP حسب تصميم الإنتاج | `/usr/local/sbin/coovox-rtp-forward` |
| `coovox-registrations-snapshot.timer` | حفظ جدول `reg` دورياً؛ راجع سياسة حفظ `regmulti` | systemd timer |
| `/var/lib/coovox-sip/registered-contacts.sqlite` | جهات اتصال مسجلة ومخزنة (بيانات خاصة) | sqlite3 محلياً فقط |

منافذ بيئة الإصدار: UDP 15060 عام، UDP 17060 Kamailio، UDP 17061–17062 مخصصة لفروع CooCall عبر VPN، UDP 5060 داخل البدالة، UDP 22000–23999 لـRTPengine، ومنافذ PBX RTP 20000–21000 عند استخدام توجيهها الخاص. **هذه المنافذ جزء من التصميم الحالي؛ تحقق من إعدادات VPS والجدار الناري قبل اعتمادها على سيرفر آخر.**

## 3. فحوص أولية لا تغيّر شيئاً

```bash
systemctl is-active coovox-kamailio coovox-rtpengine openvpn-server@coovox
kamailio -c -f /etc/kamailio/coovox.cfg
ss -lunp | grep -E ':(17060|17061|17062|22231)'
ip addr show dev tun-coovox
cat /run/openvpn-server/status-coovox.log
kamcmd -s unix:/var/lib/coovox-sip/kamailio_ctl htable.dump reg
kamcmd -s unix:/var/lib/coovox-sip/kamailio_ctl htable.dump regmulti
```

للتحقق من الحدود الزمنية لجدول التسجيل، قارِن زمن `#ts` مع `date +%s`. يحتفظ جدول `regmulti` بمفاتيح `100#1`، `100#2`... والعناصر `100#1#ts`... لا تستخدم الرقم أو المنفذ وحده لتحديد اسم الجهاز دون فحص User-Agent أو سجل REGISTER.

## 4. تشخيص تسجيل SIP

### الحالة A: `Timeout` أو `Service Unavailable`

1. تأكد أن عنوان `SIP Server` صحيح وأن المنفذ `15060` والنقل UDP.
2. تأكد أن الخدمة تعمل وأن تحويل NAT العام يسبق DNAT القديم.
3. راقب الطلبات لدقائق حسب `Registration Expiration` (مثل 60 أو 300 ثانية):

```bash
sudo tcpdump -ni eth0 -s 400 'udp port 15060'
sudo tcpdump -ni tun-coovox -s 400 'udp port 5060'
sudo nft list chain ip nat PREROUTING
sudo journalctl -u coovox-kamailio --since '10 minutes ago' --no-pager
```

إذا وصل طلب UDP 15060 إلى eth0 ولم يخرج من واجهة VPN، راجع قواعد التوجيه وكود Kamailio، وليس كلمة المرور أولاً. إذا خرج عبر VPN ولم يرد جهاز البدالة، افحص الـVPN وخدمة SIP داخل CooVox.

### الحالة A2: هاتف لا يسجّل لأنه يشير إلى خادم ZYCOO السحابي

في 30 أكتوبر 2026، لم يكن الرقمان **105 و107** مسجّلين في Kamailio، بينما كانت الأرقام الأخرى تعمل. اتضح أن **Server Address** في الهاتفين كان مضبوطاً على خادم ZYCOO السحابي (`*.uae.zycoo.com`) بدلاً من خادم الربط الخاص بالمشروع. بمجرد تحويل عنوان SIP في الجهازين إلى خادم المشروع وضبط منفذ SIP الصحيح والنقل UDP، سُجّل الرقمان بنجاح وظهرا في جدولي `reg` و`regmulti`، دون أي تعديل على Kamailio أو كلمات المرور.

عندما لا تظهر أي محاولة `REGISTER` من جهاز معروف في سجلات السيرفر، **افحص عنوان خادم SIP داخل الجهاز قبل تغيير حماية الشبكة**:

1. افتح إعدادات حساب SIP على Fanvil أو MicroSIP.
2. طابق `Server Address` مع اسم خادم SIP المستخدم فعلياً في بيئتك، وليس عنوان خدمة ZYCOO السحابية الافتراضية.
3. تأكد من المنفذ العام (مثل `15060` في بيئة المشروع) و`Transport: UDP`.
4. احفظ الإعداد ثم راقب تسجيل الجهاز في `reg` و`regmulti`.
5. إذا بقي الجهاز غير مسجّل، ابدأ عندها تتبع `REGISTER` والردود؛ لا تغيّر كلمة المرور عشوائياً.

> عنوان `sip.alshulaads.com` يخص بيئة المشروع الأصلية فقط. في البيئات الجديدة استعمل قيمة `SIP_PUBLIC_HOST` من إعداداتها الخاصة، ولا تنسخ عنوان الإنتاج حرفياً.

### الحالة B: `401 Unauthorized`

**أول رد 401 طبيعي** في SIP Digest: البدالة تطلب بيانات مصادقة. المهم هو الرد التالي بعد وصول `Authorization: Digest`. إذا أعادت البدالة 401 مراراً حتى بعد استلام بيانات المصادقة، فافحص `Username` و`Authentication User` وSIP Password داخل البدالة والجهاز، وصلاحية الحساب و`Realm` إن كان محدداً. لا تنشر Header المصادقة ولا تتبادل كلمات المرور عبر المحادثات أو Issues. خطأ 151 في سجل المشروع كان من هذا النوع، وليس نتيجة لانقطاع Kamailio.

### الحالة C: `503 REGISTER Rate Limited`

الحد في v1.0.0 هو `120 REGISTER/60s` لكل عنوان مصدر، باستخدام عداد `regiplimit` ووقت بدء نافذة `regipwindow`. إذا كان عدة هواتف تشارك IP بسبب CGNAT، فقد تتداخل تسجيلاتها. اطلع على الأعداد:

```bash
kamcmd -s unix:/var/lib/coovox-sip/kamailio_ctl htable.dump regiplimit
kamcmd -s unix:/var/lib/coovox-sip/kamailio_ctl htable.dump regipwindow
```

لا تزل الحماية عشوائياً. في نسخة سابقة كان العداد يتجدد بلا حد زمني فعلي، فحُظرت هواتف سليمة. الإصدار الحالي يستخدم نافذة زمنية ثابتة.

### الحالة D: جهاز مسجّل لكن لا يستقبل مكالمات

هذا كان السبب الأصلي لمشكلة Fanvil: فرع SIP ثانوي خرج بعنوان مصدر VPN الداخلي بدل عنوان السيرفر العام. حُل عبر:

```kamailio
# داخل مسار INVITE الوارد من البدالة
t_on_branch("PUBLIC_FORK");

branch_route[PUBLIC_FORK] {
    set_send_socket("udp:PUBLIC_IP:17060");
}
```

الكود أعلاه توضيحي فقط؛ `PUBLIC_IP` ليس نصاً قابلاً للتشغيل. استخدم قالب الإعداد الفعلي ومولّد `render_config.py`. **لا تعتمد على `force_send_socket` في المسار الرئيسي وحده**؛ يجب أيضاً توجيه كل فرع من فروع TM.

للتحقق العملي من الفرع، اتصل من 112 إلى 100 وراقب المصدر والوجهة لرسالة `INVITE` على eth0. ينبغي أن تخرج إلى كل منفذ مسجل من **عنوان السيرفر العام**، ثم يصل `180 Ringing` من الجهاز المستجيب. إذا خرجت من VPN_IP فلن يرن بعض هواتف الإنترنت رغم كونها `Registered`.

## 5. تعدد الأجهزة على الرقم الواحد

المثال الذي ثبت في الإنتاج: MicroSIP وFanvil يسجلان بالرقم `100`، وتطبيق CooCall يسجل على `app_100`. على CooVox يكون خيار `Number Of Simultaneous Registrations` مناسباً لعدد الأجهزة الفعلي (كان مضبوطاً على 5 في حالة المشروع).

Kamailio يسجل كل جهاز خارجي عادي بمفتاح `100#N` حتى خمسة، ويحفظ آخر وقت للرد `200 OK` من البدالة. الرنين الوارد ينشئ فروعاً للأجهزة الحديثة ذات الجدول الصالح (حد صلاحية الاستخدام 3600 ثانية)، ويضيف `app_100` عند وجوده. لا يخلط الرقم العادي مع `app_100`.

عند توقف جهاز عن التسجيل لا تحذف امتداد 100 كله، ولا تضبط كلمة مروره من جديد. افحص سجل الجهاز، ووقت `#ts`، وهل عنوان UDP/المنفذ تغير بفعل NAT. برنامج MicroSIP قد يرسل حزمة keep-alive قصيرة، وFanvil قد يرسل حزمة بطول مختلف؛ **ليست هذه قرينة كافية وحدها** لتحديد هوية الجهاز.

## 6. تشخيص الرنين خطوة بخطوة

نفّذ في فترة صيانة أو عندما يسمح مستخدمو الخط بذلك:

```bash
sudo tcpdump -ni any -s 320 -w /root/ring-test.pcap 'udp and (port 15060 or port 17060 or port 5060)'
# في نافذة منفصلة: اتصل من رقم داخلي إلى الرقم المطلوب
# أوقف التسجيل خلال ثوانٍ بمجرد انتهاء الاختبار
sudo tcpdump -nn -tttt -r /root/ring-test.pcap | grep -E 'INVITE|180 Ringing|200 OK|CANCEL'
```

**تحذير الخصوصية:** ملف PCAP يحتوي عناوين أجهزة، أرقاماً وربما محتوى SIP حساساً؛ لا ترفعه إلى GitHub ولا تشاركه علناً، وامسحه عند انتهاء الحاجة إليه. إذا وصل INVITE إلى كل الأجهزة لكن أحدها لم يرن، افحص رد الجهاز ومصدر الحزمة وتوقيت الشبكة. إذا وصل فقط لجهاز واحد، افحص جدول `regmulti` وفروع TM.

## 7. عند فشل الصوت أو انعدام الصوت في أحد الاتجاهين

```bash
systemctl is-active coovox-rtpengine
ss -Huanp | grep rtpengine | wc -l
journalctl -u coovox-kamailio --since '10 minutes ago' --no-pager | grep -Ei 'rtpengine|Ran out of ports|488'
cat /etc/rtpengine/coovox.conf
ip link show tun-coovox
```

إذا ظهر `Ran out of ports` فلا توسّع المنافذ عشوائياً. تحقق أولاً أن SIP guard يرفض INVITE غير المسجل **قبل تخصيص RTPengine**. سابقاً كانت طلبات اتصال SIP آلية تستهلك تقريباً كل المجال الصوتي؛ أصحبت مرفوضة قبل الحجز. لا تعِد تشغيل RTPengine خلال مكالمات حية إلا في نافذة صيانة لأن جلسات الصوت قد تنقطع. تحقق من قواعد الفايروول ونطاق RTP المستخدم فعلياً.

تم استخدام `mtu 1280` على واجهة VPN في بيئة المشروع لأن رسائل SIP الكبيرة قد تضيع في الطريق عند التجزئة. **لا تفترض أن MTU=1280 مناسب لكل الشبكات**؛ افحصه عملياً.

## 8. مشاكل CooCall الخاصة

- يستخدم التطبيق `app_100` كنمط تسجيل منفصل عن `100`، وله توجيه Socket داخلي `17061/17062`.
- قد تتغير منافذ NAT على الآيفون، ويحتاج التجديد إلى تحديث العنوان.
- في سجلات التجارب قد تظهر `481 Subscription Does Not Exist` أو `408` لرسائل `NOTIFY/OPTIONS`؛ لا تعادل هذه بمفردها فشل المكالمة.
- لا تُزل معالجة `app_100` أو `PUBLIC_FORK` عند تعديل الرنين المتعدد من أجل هاتف آخر.

## 9. النسخ الاحتياطي والترقية

1. راجع حالة الخدمات ثم نفّذ `sudo scripts/backup.sh` من نسخة عمل موثوقة.
2. أنشئ Branch منفصلاً على GitHub، ثم شغّل `python3 -m unittest discover -s tests -v`.
3. ولّد الإعداد من القالب وفق بيئة خاصة؛ لا تنشر `.env`.
4. اختبر `kamailio -c -f <file>`، ثم اختبارات الحلقة المعزولة إن توافرت.
5. احتفظ بالملف الأصلي وبقاعدة البيانات قبل إعادة تشغيل `coovox-kamailio`.
6. اختبر تسجيل جهازين، رنينهما، استقبال CooCall، اتصالاً باتجاهين، وحالة PBX بعد تجديد التسجيل.
7. إذا فشل أي اختبار، استخدم دليل [RESTORE.md](RESTORE.md)، ولا تغيّر عدة طبقات دفعة واحدة.

## 10. ما الذي لا نعتبره منجزاً؟

- **مشكلة 151:** أعاد `401` بعد Digest، وهي بحاجة لفحص حسابه في البدالة لا للالتفاف على الحماية.
- **تسجيل صوت المكالمات داخل CooVox:** خيار `In & Out` ظهر في الواجهة، لكن لم نؤكد إصلاح ملفات الصوت.
- **نجاح الاتصال الصوتي على كل جهاز/شبكة مستقبلية:** يحتاج اختباراً مستقلاً بعد تحديثات firmware أو تغيّر NAT.

## 11. أخطاء يجب تجنبها

- لا تحوّل UDP 15060 مباشرة إلى PBX إذا أردت استمرار عمل مسار Kamailio وتعدد الأجهزة.
- لا تجعل قاعدة DNAT القديمة تسبق قاعدة REDIRECT الأساسية.
- لا تصفِّر `regmulti` دون نسخة احتياطية وتتبع للمكالمات.
- لا تستخدم `force_send_socket` الرئيسي بدل branch callback عند الرنين المتوازي.
- لا تُوقف حماية INVITE لمجرد وجود رقم 100 في Header `From`: الرقم وحده ليس مصادقة.
- لا ترفع `/etc/openvpn/`، ملفات الأسرار، `.env` الفعلي أو سجل `tcpdump` على GitHub.
- لا تعد بتسجيل الصوت أو إزالة جميع مشاكل NAT لمجرد أن SIP Registration أصبح `200 OK`.

للتفاصيل الفنية الكاملة راجع [TECHNICAL_REFERENCE.md](TECHNICAL_REFERENCE.md)، وللاسترجاع راجع [RESTORE.md](RESTORE.md).
