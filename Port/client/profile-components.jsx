import { Accordion, Avatar, Badge, Box, Button, Card, Code, Heading, HStack, IconButton, Image, Stack, Text } from "@chakra-ui/react";
import { LuBookmark, LuCopy, LuExternalLink, LuMapPin } from "react-icons/lu";
import { brandIconSlug, initials, paymentMark, paymentType, platform } from "./catalog.js";

export function BrandIcon({ id, mark }) {
  const slug = brandIconSlug(id);
  return (
    <Box as="span" className="brand-icon">
      <span>{mark}</span>
      {slug ? <img src={`https://cdn.simpleicons.org/${encodeURIComponent(slug)}`} alt="" loading="lazy" onError={(event) => event.currentTarget.remove()} /> : null}
    </Box>
  );
}

export function BookmarkButton({ slug, active, hidden, onToggle, className = "" }) {
  if (hidden) return null;
  return (
    <IconButton
      className={className}
      type="button"
      size="sm"
      variant={active ? "solid" : "outline"}
      aria-label={active ? "ブックマークから削除" : "ブックマークに追加"}
      onClick={() => onToggle(slug)}
    >
      <LuBookmark fill={active ? "currentColor" : "none"} />
    </IconButton>
  );
}

export function DiscoveryCard({ profile, bookmarked, owned, onToggleBookmark }) {
  const accent = /^#[0-9a-f]{6}$/iu.test(profile.accent || "") ? profile.accent : "#5b5cf0";
  const links = (profile.links || []).filter((link) => link.url).slice(0, 7);
  return (
    <Card.Root as="article" className="discovery-card" data-profile-slug={profile.slug} style={{ "--profile-accent": accent }} variant="elevated" overflow="hidden">
      <BookmarkButton slug={profile.slug} active={bookmarked} hidden={owned} onToggle={onToggleBookmark} className="discovery-bookmark" />
      <Box asChild className="discovery-cover">
        <a href={`/u/${encodeURIComponent(profile.slug)}`} aria-label={`${profile.displayName}のプロフィールを見る`}>
          {profile.coverUrl ? <Image src={profile.coverUrl} alt="" loading="lazy" width="100%" height="100%" objectFit="cover" /> : <span className="discovery-cover-pattern" />}
        </a>
      </Box>
      <Card.Body className="discovery-body">
        <Box asChild className="discovery-person">
          <a href={`/u/${encodeURIComponent(profile.slug)}`}>
            <Avatar.Root className="discovery-avatar"><Avatar.Fallback name={profile.displayName}>{initials(profile.displayName)}</Avatar.Fallback>{profile.avatarUrl ? <Avatar.Image src={profile.avatarUrl} alt="" /> : null}</Avatar.Root>
            <span className="discovery-copy"><Heading as="strong" size="lg">{profile.displayName}</Heading>{profile.headline ? <Text as="span">{profile.headline}</Text> : null}{profile.location ? <HStack as="small" gap="1"><LuMapPin />{profile.location}</HStack> : null}</span>
            <Box className="discovery-open"><LuExternalLink /></Box>
          </a>
        </Box>
        {profile.bio ? <Text className="discovery-bio">{profile.bio}</Text> : null}
        {links.length ? <Stack className="discovery-links">{links.map((link) => <DiscoveryLink key={link.id} link={link} />)}</Stack> : null}
      </Card.Body>
    </Card.Root>
  );
}

function DiscoveryLink({ link }) {
  const service = platform(link.platform);
  return (
    <Button asChild variant="outline" size="sm" height="auto" minHeight="14" padding="2" justifyContent="flex-start" whiteSpace="normal">
      <a className="discovery-link" href={link.url} target="_blank" rel="me noopener noreferrer">
        <span className="discovery-link-thumb">{link.thumbnailUrl ? <Image src={link.thumbnailUrl} alt="" loading="lazy" /> : <BrandIcon id={service.id} mark={service.mark} />}</span>
        <Stack className="discovery-link-copy" gap="0" align="flex-start"><Text as="small" color="fg.muted">{service.label}</Text><Text as="strong" truncate>{link.label || service.label}</Text></Stack><LuExternalLink />
      </a>
    </Button>
  );
}

export function ProfileView({ profile, variant = "public", actions = null, onCopy }) {
  const compact = variant === "preview";
  const links = (profile.links || []).filter((link) => link.url);
  const payments = (profile.payments || []).filter((payment) => payment.destination);
  return (
    <>
      <Box className={`profile-cover ${profile.coverUrl ? "has-image" : ""}`}>
        {profile.coverUrl ? <Image src={profile.coverUrl} alt="" loading="lazy" width="100%" height="100%" objectFit="cover" /> : null}<span className="cover-noise" />
      </Box>
      <Box className="profile-content">
        <Box className="profile-identity">
          <Avatar.Root className="profile-avatar"><Avatar.Fallback name={profile.displayName}>{initials(profile.displayName)}</Avatar.Fallback>{profile.avatarUrl ? <Avatar.Image src={profile.avatarUrl} alt="" loading={compact ? "lazy" : "eager"} /> : null}</Avatar.Root>
          <HStack className="profile-actions">{actions}</HStack>
          <Heading as="h1" size="3xl">{profile.displayName || "表示名"}</Heading>
          {profile.headline ? <Text className="profile-headline">{profile.headline}</Text> : null}
          {profile.location ? <HStack className="profile-location" gap="1"><LuMapPin />{profile.location}</HStack> : null}
          {profile.bio ? <Text className="profile-bio">{profile.bio}</Text> : null}
        </Box>
        {links.length ? <Box as="section" className="profile-section"><HStack className="profile-section-title" justify="space-between"><Heading size="sm">Links &amp; Works</Heading><Badge variant="subtle">{links.length}</Badge></HStack><Stack className="profile-links">{links.map((link) => <ProfileLink key={link.id} link={link} />)}</Stack></Box> : null}
        {payments.length ? <Box as="section" className="profile-section payment-section"><HStack className="profile-section-title" justify="space-between"><Heading size="sm">Payment</Heading><Badge variant="subtle">{payments.length}</Badge></HStack><Text className="payment-notice">振込前に名義と内容を確認してください。</Text><Stack className="payment-list">{payments.map((payment) => <PaymentCard key={payment.id} payment={payment} onCopy={onCopy} />)}</Stack></Box> : null}
        {!links.length && !payments.length ? <Card.Root variant="outline" marginTop="8"><Card.Body><Text color="fg.muted" textAlign="center">リンクを追加するとここに表示されます。</Text></Card.Body></Card.Root> : null}
      </Box>
    </>
  );
}

function ProfileLink({ link }) {
  const service = platform(link.platform);
  return (
    <Button asChild variant="outline" height="auto" minHeight="20" width="100%" padding="3" justifyContent="flex-start" whiteSpace="normal">
      <a className="profile-link-card" href={link.url} target="_blank" rel="me noopener noreferrer">
        <span className="link-thumb">{link.thumbnailUrl ? <Image src={link.thumbnailUrl} alt="" loading="lazy" /> : <span className="link-placeholder"><BrandIcon id={service.id} mark={service.mark} /></span>}</span>
        <Stack className="link-copy" gap="0" align="flex-start"><Text as="small" color="fg.muted">{service.label}</Text><Text as="strong" truncate>{link.label || service.label}</Text>{link.description ? <Text as="span" color="fg.muted" textStyle="sm" truncate>{link.description}</Text> : null}</Stack>
        <LuExternalLink className="link-arrow" />
      </a>
    </Button>
  );
}

function PaymentCard({ payment, onCopy }) {
  const type = paymentType(payment.type);
  return (
    <Accordion.Root collapsible variant="outline">
      <Accordion.Item value={payment.id}>
        <Accordion.ItemTrigger>
          <HStack flex="1" gap="3"><Box width="8" height="8"><BrandIcon id={payment.type} mark={paymentMark(payment.type)} /></Box><Box textAlign="left"><Text textStyle="xs" color="fg.muted">{type.label}</Text><Text fontWeight="semibold">{payment.label || type.label}</Text></Box></HStack>
          <Accordion.ItemIndicator />
        </Accordion.ItemTrigger>
        <Accordion.ItemContent><Accordion.ItemBody><Stack gap="3"><Code display="block" padding="3" whiteSpace="pre-wrap" wordBreak="break-all">{payment.destination}</Code>{payment.note ? <Text color="fg.muted" textStyle="sm">{payment.note}</Text> : null}<HStack><Button size="sm" variant="outline" onClick={() => onCopy(payment.destination)}><LuCopy />コピー</Button>{payment.url ? <Button asChild size="sm"><a href={payment.url} target="_blank" rel="noopener noreferrer"><LuExternalLink />送金ページ</a></Button> : null}</HStack></Stack></Accordion.ItemBody></Accordion.ItemContent>
      </Accordion.Item>
    </Accordion.Root>
  );
}
