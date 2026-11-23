# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

The app is a native iPhone app (SwiftUI, Core Haptics, spatial audio). The
marketing landing page is a separate static web surface.

## Stack

Landing page: plain static HTML/CSS, hosted free on Vercel (confirmed by Edison,
Nov 23, 2026).

## Users

- App: blind and low-vision home buyers who want to learn a home's layout
  before or instead of a sighted walkthrough.
- Landing page: real estate agents. They don't use the app themselves. They
  would offer it to blind or low-vision clients so those clients can explore a
  listing's floor plan independently.

## Product Purpose

Haptix turns a listing's floor plan into something you can feel and hear. A
blind buyer drags a finger on a hidden map to walk an avatar through the
house. Walls, doors, windows, stairs, and floor types each have their own
vibration, and 3D sound gives direction to places like the front door. Voice
questions ("where am I", "take me to the kitchen") and a guided tour fill in
the rest. Success for the landing page is an agent booking a 15-minute demo.

## Positioning

A floor plan is a picture, and a virtual tour is a video. Both are visual.
Haptix is a floor plan you explore by touch and sound, at your own pace, with
no sighted guide narrating it for you.

## Operating Context

- Demos are given by the team over video call by default, or in person for
  Champaign-area agents.
- Each house is traced from its listing floor plan into the app by the team.
  Two houses exist: 2011 O'Donnell Dr, Champaign, IL, and the Waterville plan.

## Capabilities and Constraints

- Runs on iPhone only, installed from Xcode. Agents cannot install it
  themselves. No App Store or TestFlight build exists (TestFlight undecided).
- AirPods Pro head tracking turns the avatar; works without it too.
- A laptop viewer shows the plan, the avatar, and live sound and haptic events
  for sighted people watching a session.
- Undecided: domain name, the team inbox that receives demo requests, pricing.

## Brand Commitments

- Public name: Haptix. The repo and app code still say "House Tour".
- Team: Edison Hui, Pradyun Pinapala, Devansh Lal, Jonathan Zhao.

## Evidence on Hand

- 3rd place and $500 at the Hack to the Future hackathon, Oct 2 to 3, 2026.
- A low-quality demo video from the hackathon (not yet in the repo).
- No blind or low-vision user has tested it yet. Never claim user testing,
  testimonials, customers, partners, or accessibility certifications.

## Product Principles

1. Anything the avatar touches is haptic, anything about direction is audio,
   and words are for names.
2. Calm by default. Every channel can be switched off.
3. The buyer explores alone and at their own pace.
4. Claim only what has been shown working.

## Accessibility & Inclusion

The landing page must work fully with a screen reader (VoiceOver, NVDA) and
keyboard alone, meeting WCAG 2.2 AA. Blind visitors may land on it, and an
accessibility product with an inaccessible page loses agents' trust.
