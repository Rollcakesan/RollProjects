import { Alert, Avatar, Box, Button, EmptyState, Heading, Spinner, Stack, Text } from "@chakra-ui/react";
import { LuCircleAlert, LuInbox } from "react-icons/lu";
import { initials } from "./catalog.js";

export function LinkButton({ href, children, ...props }) {
  return <Button asChild {...props}><a href={href}>{children}</a></Button>;
}

export function UserAvatar({ name, src, size = "sm" }) {
  return <Avatar.Root size={size}><Avatar.Fallback name={name}>{initials(name)}</Avatar.Fallback>{src ? <Avatar.Image src={src} alt="" /> : null}</Avatar.Root>;
}

export function LoadingState({ label = "読み込んでいます" }) {
  return <Stack minHeight="60vh" align="center" justify="center" gap="4"><Spinner size="lg" /><Text color="fg.muted">{label}</Text></Stack>;
}

export function MessagePage({ message }) {
  return <EmptyState.Root minHeight="60vh"><EmptyState.Content><EmptyState.Indicator><LuCircleAlert /></EmptyState.Indicator><EmptyState.Title>ページを表示できません</EmptyState.Title><EmptyState.Description>{message}</EmptyState.Description><LinkButton href="/" variant="solid">ホームへ戻る</LinkButton></EmptyState.Content></EmptyState.Root>;
}

export function EmptyContent({ title, description, action = null }) {
  return <EmptyState.Root minHeight="32vh"><EmptyState.Content><EmptyState.Indicator><LuInbox /></EmptyState.Indicator><EmptyState.Title>{title}</EmptyState.Title>{description ? <EmptyState.Description>{description}</EmptyState.Description> : null}{action}</EmptyState.Content></EmptyState.Root>;
}

export function StatusAlert({ state }) {
  if (!state.visible) return null;
  return <Box position="fixed" right={{ base: "4", md: "6" }} bottom={{ base: "4", md: "6" }} zIndex="toast" maxWidth="sm"><Alert.Root status={state.error ? "error" : "success"} variant="solid" borderRadius="md" boxShadow="lg"><Alert.Indicator /><Alert.Title>{state.message}</Alert.Title></Alert.Root></Box>;
}

export function SectionHeading({ title, count }) {
  return <Stack direction="row" align="center" justify="space-between"><Heading size="md">{title}</Heading>{count === undefined ? null : <Text color="fg.muted" textStyle="sm">{count}</Text>}</Stack>;
}
