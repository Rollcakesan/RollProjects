import { Box, Drawer, IconButton, Portal } from "@chakra-ui/react";
import { useState } from "react";
import { LuBookmark, LuHouse, LuLogOut, LuMenu, LuSettings, LuX } from "react-icons/lu";

const destinations = [
  { href: "/", label: "ホーム", icon: LuHouse },
  { href: "/bookmarks", label: "ブックマーク", icon: LuBookmark },
  { href: "/settings", label: "設定", icon: LuSettings },
];

export function NavigationDrawer({ currentPath, onSignOut }) {
  const [open, setOpen] = useState(false);
  return (
    <Drawer.Root open={open} placement="start" size="xs" onOpenChange={(details) => setOpen(details.open)}>
      <Drawer.Trigger asChild>
        <IconButton aria-label="メニュー" size="sm" variant="outline" borderRadius="full">
          <LuMenu />
        </IconButton>
      </Drawer.Trigger>
      <Portal>
        <Drawer.Backdrop background="blackAlpha.500" backdropFilter="blur(3px)" />
        <Drawer.Positioner justifyContent="flex-start">
          <Drawer.Content
            width={{ base: "74px", md: "82px" }}
            maxWidth={{ base: "74px", md: "82px" }}
            height="100%"
            background="white"
            borderRightWidth="1px"
            borderColor="gray.200"
            borderRadius="0 20px 20px 0"
            boxShadow="18px 0 55px rgba(18, 17, 14, 0.16)"
          >
            <Drawer.Body display="flex" alignItems="center" flexDirection="column" paddingX="3" paddingY="4">
              <Drawer.CloseTrigger asChild>
                <IconButton aria-label="閉じる" size="sm" variant="ghost" borderRadius="full" position="static">
                  <LuX />
                </IconButton>
              </Drawer.CloseTrigger>
              <Box as="nav" aria-label="メインメニュー" display="grid" gap="2" marginTop="8">
                {destinations.map((destination) => (
                  <NavigationLink
                    key={destination.href}
                    {...destination}
                    active={currentPath === destination.href}
                    onNavigate={() => setOpen(false)}
                  />
                ))}
              </Box>
              <IconButton
                aria-label="サインアウト"
                size="sm"
                variant="ghost"
                borderRadius="full"
                color="red.600"
                marginTop="auto"
                onClick={() => {
                  setOpen(false);
                  onSignOut();
                }}
              >
                <LuLogOut />
              </IconButton>
            </Drawer.Body>
          </Drawer.Content>
        </Drawer.Positioner>
      </Portal>
    </Drawer.Root>
  );
}

function NavigationLink({ href, label, icon: NavigationIcon, active, onNavigate }) {
  return (
    <IconButton
      asChild
      aria-label={label}
      size="sm"
      variant={active ? "solid" : "ghost"}
      borderRadius="full"
      background={active ? "gray.950" : undefined}
      color={active ? "white" : "gray.600"}
    >
      <a href={href} aria-current={active ? "page" : undefined} onClick={onNavigate}>
        <NavigationIcon />
      </a>
    </IconButton>
  );
}
