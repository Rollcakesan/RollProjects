import { useEffect, useRef, useState } from "react";
import { Accordion, Alert, AspectRatio, Avatar, Badge, Box, Button, Card, Code, Container, Field as ChakraField, Flex, Heading, HStack, IconButton, Image, Input, NativeSelect, SimpleGrid, Stack, Tabs, Text, Textarea } from "@chakra-ui/react";
import { LuCheck, LuExternalLink, LuGripVertical, LuImage, LuPlus, LuTrash2 } from "react-icons/lu";
import { api } from "./api.js";
import { PAYMENT_TYPES, PLATFORMS, blankProfile, normalizeUrlInput, platform, profileSummary } from "./catalog.js";
import { ProfileView } from "./profile-components.jsx";
import { LinkButton, LoadingState, MessagePage } from "./ui.jsx";

export function ProfileEditor({ mode, routeSlug = "", ownedProfiles, navigate, showToast, onCreated, onUpdated, onDeleted, onCopy }) {
  const [slug, setSlug] = useState(routeSlug);
  const [draft, setDraft] = useState(blankProfile);
  const [activeSection, setActiveSection] = useState("profile");
  const [loading, setLoading] = useState(mode === "edit");
  const [saving, setSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState("");
  const [created, setCreated] = useState(false);
  const [openLinks, setOpenLinks] = useState(new Set());
  const [openPayments, setOpenPayments] = useState(new Set());
  const [sortingId, setSortingId] = useState("");
  const sortCleanup = useRef(null);

  useEffect(() => {
    setSlug(routeSlug);
    setDraft(blankProfile());
    setActiveSection("profile");
    setCreated(false);
    setError("");
    if (mode !== "edit") {
      setLoading(false);
      return undefined;
    }
    if (!ownedProfiles.some((profile) => profile.slug === routeSlug)) {
      setError("このプロフィールを編集する権限がありません。");
      setLoading(false);
      return undefined;
    }
    const controller = new AbortController();
    setLoading(true);
    api(`/api/profiles/${encodeURIComponent(routeSlug)}`, { signal: controller.signal })
      .then((payload) => {
        setDraft(structuredClone(payload.profile));
        setOpenLinks(new Set(payload.profile.links?.[0] ? [payload.profile.links[0].id] : []));
        setOpenPayments(new Set(payload.profile.payments?.[0] ? [payload.profile.payments[0].id] : []));
      })
      .catch((requestError) => {
        if (requestError.name !== "AbortError") setError(requestError.message);
      })
      .finally(() => setLoading(false));
    return () => controller.abort();
  }, [mode, routeSlug]);

  useEffect(() => () => sortCleanup.current?.(), []);

  if (loading) return <LoadingState label="プロフィールを読み込んでいます" />;
  if (error) return <MessagePage message={error} />;
  if (created) return <CreatedPage slug={slug} onCopy={onCopy} />;

  const isEdit = mode === "edit";
  const updateField = (field, value) => setDraft((current) => ({ ...current, [field]: value }));
  const updateCollectionItem = (collection, id, field, value) => {
    setDraft((current) => ({
      ...current,
      [collection]: current[collection].map((item) => {
        if (item.id !== id) return item;
        const updated = { ...item, [field]: value };
        if (collection === "links" && field === "platform" && !updated.label) updated.label = platform(value).label;
        return updated;
      }),
    }));
  };

  const addLink = () => {
    if (draft.links.length >= 48) return showToast("リンクは48件までです。", true);
    const id = crypto.randomUUID();
    setDraft((current) => ({ ...current, links: [...current.links, { id, platform: "website", label: "", description: "", url: "", thumbnailUrl: "" }] }));
    setOpenLinks((current) => new Set(current).add(id));
  };
  const addPayment = () => {
    if (draft.payments.length >= 12) return showToast("振込・送金先は12件までです。", true);
    const id = crypto.randomUUID();
    setDraft((current) => ({ ...current, payments: [...current.payments, { id, type: "bank", label: "", destination: "", note: "", url: "" }] }));
    setOpenPayments((current) => new Set(current).add(id));
  };
  const removeItem = (collection, id) => setDraft((current) => ({ ...current, [collection]: current[collection].filter((item) => item.id !== id) }));

  const handleImage = async (target, file) => {
    if (!file) return;
    try {
      showToast("画像を処理しています…");
      const dataUrl = await compressImage(file, target === "avatar" ? 512 : 1_200, target === "avatar" ? 512 : 700);
      if (target === "avatar" || target === "cover") updateField(`${target}Url`, dataUrl);
      else updateCollectionItem("links", target.slice(5), "thumbnailUrl", dataUrl);
    } catch (imageError) {
      showToast(imageError.message, true);
    }
  };
  const clearImage = (target) => {
    if (target === "avatar" || target === "cover") updateField(`${target}Url`, "");
    else updateCollectionItem("links", target.slice(5), "thumbnailUrl", "");
  };

  const moveItem = (collection, id, targetId) => {
    if (id === targetId) return;
    setDraft((current) => {
      const items = [...current[collection]];
      const from = items.findIndex((item) => item.id === id);
      const to = items.findIndex((item) => item.id === targetId);
      if (from < 0 || to < 0) return current;
      const [item] = items.splice(from, 1);
      items.splice(to, 0, item);
      return { ...current, [collection]: items };
    });
  };
  const moveByOffset = (collection, id, offset) => {
    setDraft((current) => {
      const items = [...current[collection]];
      const from = items.findIndex((item) => item.id === id);
      const to = from + offset;
      if (from < 0 || to < 0 || to >= items.length) return current;
      const [item] = items.splice(from, 1);
      items.splice(to, 0, item);
      return { ...current, [collection]: items };
    });
  };
  const beginSort = (collection, id, event) => {
    if (event.button !== 0 || draft[collection].length < 2) return;
    event.preventDefault();
    setSortingId(id);
    const move = (moveEvent) => {
      const target = document.elementFromPoint(moveEvent.clientX, moveEvent.clientY)?.closest(`[data-sortable-collection="${collection}"] [data-sortable-id]`);
      if (target?.dataset.sortableId) moveItem(collection, id, target.dataset.sortableId);
      if (moveEvent.clientY < 80) window.scrollBy({ top: -18, behavior: "auto" });
      else if (moveEvent.clientY > window.innerHeight - 80) window.scrollBy({ top: 18, behavior: "auto" });
    };
    const finish = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", finish);
      window.removeEventListener("pointercancel", finish);
      setSortingId("");
      sortCleanup.current = null;
    };
    sortCleanup.current?.();
    sortCleanup.current = finish;
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", finish);
    window.addEventListener("pointercancel", finish);
  };

  const save = async (event) => {
    event.preventDefault();
    setSaving(true);
    try {
      const path = isEdit ? `/api/profiles/${encodeURIComponent(slug)}` : "/api/profiles";
      const payload = await api(path, { method: isEdit ? "PUT" : "POST", auth: true, body: JSON.stringify({ slug: slug.trim().toLowerCase(), profile: draft }) });
      setDraft(payload.profile);
      if (isEdit) {
        onUpdated(profileSummary(payload.profile));
        showToast("保存しました。");
      } else {
        setSlug(payload.profile.slug);
        onCreated(profileSummary(payload.profile));
        setCreated(true);
      }
    } catch (saveError) {
      showToast(saveError.message, true);
    } finally {
      setSaving(false);
    }
  };
  const deleteProfile = async () => {
    if (!window.confirm("このプロフィールとアップロード画像を完全に削除します。元に戻せません。削除しますか？")) return;
    setDeleting(true);
    try {
      await api(`/api/profiles/${encodeURIComponent(slug)}`, { method: "DELETE", auth: true });
      onDeleted(slug);
      navigate("/", { replace: true });
    } catch (deleteError) {
      showToast(deleteError.message, true);
      setDeleting(false);
    }
  };

  const tabs = [["profile", "Profile", ""], ["links", "Links", draft.links.length], ["payments", "Payment", draft.payments.length], ["preview", "Preview", ""]];
  return (
    <Container as="section" className="editor-shell" maxWidth="7xl" paddingY={{ base: "4", md: "8" }} data-active-section={activeSection}>
      <Flex align={{ base: "flex-start", md: "center" }} justify="space-between" gap="4" direction={{ base: "column", md: "row" }} marginBottom="6">
        <Heading size="3xl">{isEdit ? "Edit profile" : "New profile"}</Heading>
        {isEdit ? <HStack><Button colorPalette="red" variant="ghost" disabled={deleting} onClick={deleteProfile}><LuTrash2 />{deleting ? "削除中…" : "削除"}</Button><Button asChild variant="outline"><a href={`/u/${encodeURIComponent(slug)}`} target="_blank" rel="noreferrer"><LuExternalLink />公開ページ</a></Button></HStack> : null}
      </Flex>
      <Tabs.Root value={activeSection} onValueChange={(details) => setActiveSection(details.value)} variant="subtle" marginBottom="6">
        <Tabs.List overflowX="auto">{tabs.map(([id, label, count]) => <Tabs.Trigger key={id} value={id}>{label}{count !== "" ? <Badge variant="subtle">{count}</Badge> : null}</Tabs.Trigger>)}<Tabs.Indicator /></Tabs.List>
      </Tabs.Root>
      <Box className="editor-layout">
        <Box as="form" className="editor-form" onSubmit={save} onInvalidCapture={(event) => setActiveSection(event.target.closest("[data-editor-panel]")?.dataset.editorPanel || activeSection)}>
          <Card.Root data-editor-panel="profile" hidden={activeSection !== "profile"} variant="outline">
            <Card.Header><Card.Title>Profile</Card.Title></Card.Header>
            <Card.Body><Stack gap="6">
              {!isEdit ? <Field label="公開URL名" required wide helper="英数字、ハイフン、アンダースコアが使えます。"><Input value={slug} onChange={(event) => setSlug(event.target.value)} required minLength="3" maxLength="32" pattern="[a-zA-Z0-9_-]+" placeholder="your-name" /></Field> : null}
              <SimpleGrid columns={{ base: 1, md: 2 }} gap="5"><ImageField kind="avatar" label="プロフィール画像" value={draft.avatarUrl} shape="square" onImage={handleImage} onClear={clearImage} /><ImageField kind="cover" label="カバー画像" value={draft.coverUrl} shape="wide" onImage={handleImage} onClear={clearImage} /></SimpleGrid>
              <SimpleGrid columns={{ base: 1, md: 2 }} gap="5">
                <Field label="表示名" required><Input value={draft.displayName} onChange={(event) => updateField("displayName", event.target.value)} maxLength="60" required placeholder="山田 太郎" /></Field>
                <Field label="肩書き・ひとこと"><Input value={draft.headline} onChange={(event) => updateField("headline", event.target.value)} maxLength="100" placeholder="Designer / Developer" /></Field>
                <Field label="自己紹介" wide><Textarea value={draft.bio} onChange={(event) => updateField("bio", event.target.value)} maxLength="600" rows="5" placeholder="活動内容や得意なことを書いてください。" /></Field>
                <Field label="場所"><Input value={draft.location} onChange={(event) => updateField("location", event.target.value)} maxLength="80" placeholder="Niigata, Japan" /></Field>
                <Field label="アクセントカラー"><HStack><Input type="color" width="16" padding="1" value={draft.accent} onChange={(event) => updateField("accent", event.target.value)} /><Code>{draft.accent}</Code></HStack></Field>
              </SimpleGrid>
            </Stack></Card.Body>
          </Card.Root>
          <Card.Root data-editor-panel="links" hidden={activeSection !== "links"} variant="outline">
            <Card.Header><Flex justify="space-between"><Card.Title>Links</Card.Title><Badge>{draft.links.length}</Badge></Flex></Card.Header>
            <Card.Body><Stack gap="4" className={sortingId ? "is-sorting" : ""} data-sortable-collection="links">{draft.links.map((link, index) => <LinkEditor key={link.id} link={link} index={index} open={openLinks.has(link.id)} sorting={sortingId === link.id} onToggle={(open) => setOpenLinks((current) => toggleSet(current, link.id, open))} onChange={(field, value) => updateCollectionItem("links", link.id, field, value)} onRemove={() => removeItem("links", link.id)} onImage={handleImage} onClear={clearImage} onSort={(event) => beginSort("links", link.id, event)} onKeySort={(offset) => moveByOffset("links", link.id, offset)} />)}<Button type="button" variant="outline" onClick={addLink}><LuPlus />リンクを追加</Button></Stack></Card.Body>
          </Card.Root>
          <Card.Root data-editor-panel="payments" hidden={activeSection !== "payments"} variant="outline">
            <Card.Header><Flex justify="space-between"><Card.Title>Payment</Card.Title><Badge>{draft.payments.length}</Badge></Flex></Card.Header>
            <Card.Body><Stack gap="4"><Alert.Root status="warning" variant="subtle"><Alert.Indicator /><Box><Alert.Title>入力しないもの</Alert.Title><Alert.Description>暗証番号、パスワード、秘密鍵、カード番号、本人確認情報</Alert.Description></Box></Alert.Root><Stack gap="4" className={sortingId ? "is-sorting" : ""} data-sortable-collection="payments">{draft.payments.map((payment, index) => <PaymentEditor key={payment.id} payment={payment} index={index} open={openPayments.has(payment.id)} sorting={sortingId === payment.id} onToggle={(open) => setOpenPayments((current) => toggleSet(current, payment.id, open))} onChange={(field, value) => updateCollectionItem("payments", payment.id, field, value)} onRemove={() => removeItem("payments", payment.id)} onSort={(event) => beginSort("payments", payment.id, event)} onKeySort={(offset) => moveByOffset("payments", payment.id, offset)} />)}<Button type="button" variant="outline" onClick={addPayment}><LuPlus />振込・送金先を追加</Button></Stack></Stack></Card.Body>
          </Card.Root>
          <Flex justify="flex-end" paddingY="5"><Button type="submit" size="lg" loading={saving} loadingText={isEdit ? "保存中…" : "作成中…"}>{isEdit ? "保存" : "公開"}</Button></Flex>
        </Box>
        <Box as="aside" className="preview-column"><Text marginBottom="2" color="fg.muted" textStyle="xs" fontWeight="semibold">LIVE PREVIEW</Text><Box className="device-preview" style={{ "--accent": draft.accent }}><ProfileView profile={draft} variant="preview" onCopy={onCopy} /></Box></Box>
      </Box>
    </Container>
  );
}

function Field({ label, required = false, wide = false, helper = "", children }) {
  return <ChakraField.Root required={required} gridColumn={wide ? "1 / -1" : undefined}><ChakraField.Label>{label}{required ? <ChakraField.RequiredIndicator /> : null}</ChakraField.Label>{children}{helper ? <ChakraField.HelperText>{helper}</ChakraField.HelperText> : null}</ChakraField.Root>;
}

function ImageField({ kind, label, value, shape, onImage, onClear }) {
  const preview = shape === "square" ? <Avatar.Root size="2xl"><Avatar.Fallback><LuImage /></Avatar.Fallback>{value ? <Avatar.Image src={value} alt="" /> : null}</Avatar.Root> : <AspectRatio ratio={16 / 7} width="100%" maxWidth="sm" background="bg.muted" borderRadius="md" overflow="hidden">{value ? <Image src={value} alt="" objectFit="cover" /> : <Flex align="center" justify="center"><LuImage /></Flex>}</AspectRatio>;
  return <ChakraField.Root><ChakraField.Label>{label}</ChakraField.Label>{preview}<HStack><Button asChild size="sm" variant="outline"><label><input hidden type="file" accept="image/jpeg,image/png,image/webp" onChange={(event) => onImage(kind, event.target.files?.[0])} />画像を選択</label></Button>{value ? <Button type="button" size="sm" colorPalette="red" variant="ghost" onClick={() => onClear(kind)}>削除</Button> : null}</HStack></ChakraField.Root>;
}

function LinkEditor({ link, index, open, sorting, onToggle, onChange, onRemove, onImage, onClear, onSort, onKeySort }) {
  return (
    <SortableAccordion id={link.id} label={`リンク ${index + 1}`} summary={link.label || link.url || "未設定"} open={open} sorting={sorting} onToggle={onToggle} onSort={onSort} onKeySort={onKeySort}>
      <SimpleGrid columns={{ base: 1, md: 2 }} gap="4">
        <Field label="サービス"><NativeSelect.Root><NativeSelect.Field value={link.platform} onChange={(event) => onChange("platform", event.target.value)}>{PLATFORMS.map((item) => <option key={item.id} value={item.id}>{item.label}</option>)}</NativeSelect.Field><NativeSelect.Indicator /></NativeSelect.Root></Field>
        <Field label="表示名"><Input value={link.label} onChange={(event) => onChange("label", event.target.value)} maxLength="80" placeholder="GitHub" /></Field>
        <Field label="URL" required wide helper="https:// は省略できます。"><Input type="text" inputMode="url" autoCapitalize="none" spellCheck={false} value={link.url} onChange={(event) => onChange("url", event.target.value)} onBlur={(event) => onChange("url", normalizeUrlInput(event.target.value))} required placeholder="example.com" /></Field>
        <Field label="説明" wide><Input value={link.description} onChange={(event) => onChange("description", event.target.value)} maxLength="180" placeholder="プロジェクトやリンクの説明" /></Field>
        <ChakraField.Root gridColumn="1 / -1"><ChakraField.Label>サムネイル</ChakraField.Label><HStack>{link.thumbnailUrl ? <Image src={link.thumbnailUrl} alt="" width="24" height="14" borderRadius="md" objectFit="cover" /> : <Flex width="24" height="14" align="center" justify="center" background="bg.muted" borderRadius="md"><LuImage /></Flex>}<Button asChild size="sm" variant="outline"><label><input hidden type="file" accept="image/jpeg,image/png,image/webp" onChange={(event) => onImage(`link:${link.id}`, event.target.files?.[0])} />画像を選択</label></Button>{link.thumbnailUrl ? <Button type="button" size="sm" colorPalette="red" variant="ghost" onClick={() => onClear(`link:${link.id}`)}>削除</Button> : null}</HStack></ChakraField.Root>
      </SimpleGrid><Flex justify="flex-end" marginTop="4"><Button type="button" size="sm" colorPalette="red" variant="ghost" onClick={onRemove}><LuTrash2 />このリンクを削除</Button></Flex>
    </SortableAccordion>
  );
}

function PaymentEditor({ payment, index, open, sorting, onToggle, onChange, onRemove, onSort, onKeySort }) {
  return (
    <SortableAccordion id={payment.id} label={`振込・送金先 ${index + 1}`} summary={payment.label || payment.destination || "未設定"} open={open} sorting={sorting} onToggle={onToggle} onSort={onSort} onKeySort={onKeySort}>
      <SimpleGrid columns={{ base: 1, md: 2 }} gap="4">
        <Field label="種類"><NativeSelect.Root><NativeSelect.Field value={payment.type} onChange={(event) => onChange("type", event.target.value)}>{PAYMENT_TYPES.map((item) => <option key={item.id} value={item.id}>{item.label}</option>)}</NativeSelect.Field><NativeSelect.Indicator /></NativeSelect.Root></Field>
        <Field label="表示名"><Input value={payment.label} onChange={(event) => onChange("label", event.target.value)} maxLength="80" placeholder="作品代金のお振込先" /></Field>
        <Field label="振込・送金先" required wide><Textarea value={payment.destination} onChange={(event) => onChange("destination", event.target.value)} maxLength="300" rows="3" required placeholder="銀行名・支店名・口座番号・名義、または送金ID" /></Field>
        <Field label="補足" wide><Input value={payment.note} onChange={(event) => onChange("note", event.target.value)} maxLength="240" placeholder="振込名義をメッセージでお知らせください" /></Field>
        <Field label="送金ページURL" wide helper="https:// は省略できます。"><Input type="text" inputMode="url" autoCapitalize="none" spellCheck={false} value={payment.url} onChange={(event) => onChange("url", event.target.value)} onBlur={(event) => onChange("url", normalizeUrlInput(event.target.value))} placeholder="example.com/pay" /></Field>
      </SimpleGrid><Flex justify="flex-end" marginTop="4"><Button type="button" size="sm" colorPalette="red" variant="ghost" onClick={onRemove}><LuTrash2 />この振込・送金先を削除</Button></Flex>
    </SortableAccordion>
  );
}

function SortableAccordion({ id, label, summary, open, sorting, onToggle, onSort, onKeySort, children }) {
  return <Card.Root data-sortable-id={id} variant="outline" opacity={sorting ? ".72" : "1"} boxShadow={sorting ? "lg" : undefined}><Flex align="flex-start"><IconButton margin="3" size="sm" variant="ghost" aria-label={`${label}を並べ替え`} title="ドラッグして並べ替え" cursor="grab" touchAction="none" onPointerDown={onSort} onKeyDown={(event) => { if (event.key === "ArrowUp" || event.key === "ArrowDown") { event.preventDefault(); onKeySort(event.key === "ArrowUp" ? -1 : 1); } }}><LuGripVertical /></IconButton><Accordion.Root flex="1" collapsible value={open ? [id] : []} onValueChange={(details) => onToggle(details.value.includes(id))}><Accordion.Item value={id}><Accordion.ItemTrigger paddingRight="4"><Box flex="1" minWidth="0" textAlign="left"><Text fontWeight="semibold">{label}</Text><Text color="fg.muted" textStyle="sm" truncate>{summary}</Text></Box><Accordion.ItemIndicator /></Accordion.ItemTrigger><Accordion.ItemContent><Accordion.ItemBody paddingRight="4" paddingBottom="4">{children}</Accordion.ItemBody></Accordion.ItemContent></Accordion.Item></Accordion.Root></Flex></Card.Root>;
}

function CreatedPage({ slug, onCopy }) {
  const publicUrl = `${location.origin}/u/${encodeURIComponent(slug)}`;
  return <Stack as="section" minHeight="60vh" align="center" justify="center" gap="5" textAlign="center"><Avatar.Root size="2xl" colorPalette="green"><Avatar.Fallback><LuCheck /></Avatar.Fallback></Avatar.Root><Heading size="2xl">プロフィールを公開しました</Heading><Card.Root variant="outline" width="100%" maxWidth="2xl"><Card.Body><Stack gap="2"><Text color="fg.muted" textStyle="sm">公開URL</Text><Code padding="3" wordBreak="break-all">{publicUrl}</Code><Button variant="outline" onClick={() => onCopy(publicUrl)}>コピー</Button></Stack></Card.Body></Card.Root><HStack><LinkButton href={publicUrl}>公開ページを見る</LinkButton><LinkButton href={`/edit/${encodeURIComponent(slug)}`} variant="ghost">編集を続ける</LinkButton></HStack></Stack>;
}

function toggleSet(current, id, enabled) {
  const next = new Set(current);
  if (enabled) next.add(id);
  else next.delete(id);
  return next;
}

async function compressImage(file, maxWidth, maxHeight) {
  if (file.size > 12_000_000) throw new Error("12MB以下の画像を選択してください。");
  const bitmap = await createImageBitmap(file);
  let scale = Math.min(1, maxWidth / bitmap.width, maxHeight / bitmap.height);
  const canvas = document.createElement("canvas");
  let blob;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/webp", Math.max(0.58, 0.84 - attempt * 0.08)));
    if (blob && blob.size <= 500_000) break;
    scale *= 0.78;
  }
  bitmap.close();
  if (!blob) throw new Error("画像を変換できませんでした。");
  if (blob.size > 500_000) throw new Error("画像を十分に圧縮できませんでした。別の画像を選択してください。");
  return await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error("画像を読み取れませんでした。"));
    reader.readAsDataURL(blob);
  });
}
